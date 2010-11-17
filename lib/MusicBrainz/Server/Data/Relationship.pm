package MusicBrainz::Server::Data::Relationship;

use Moose;
use Readonly;
use Sql;
use Carp qw( carp croak );
use MusicBrainz::Server::Entity::Relationship;
use MusicBrainz::Server::Data::Artist;
use MusicBrainz::Server::Data::Label;
use MusicBrainz::Server::Data::Link;
use MusicBrainz::Server::Data::LinkType;
use MusicBrainz::Server::Data::Recording;
use MusicBrainz::Server::Data::ReleaseGroup;
use MusicBrainz::Server::Data::URL;
use MusicBrainz::Server::Data::Work;
use MusicBrainz::Server::Data::Utils qw( placeholders type_to_model );

extends 'MusicBrainz::Server::Data::Entity';

Readonly my @TYPES => qw(
    artist
    label
    recording
    release
    release_group
    url
    work
);

my %TYPES = map { $_ => 1} @TYPES;

Readonly my %ENTITY_CLASS_TO_TYPE => (
    'MusicBrainz::Server::Entity::Artist'       => 'artist',
    'MusicBrainz::Server::Entity::Label'        => 'label',
    'MusicBrainz::Server::Entity::Recording'    => 'recording',
    'MusicBrainz::Server::Entity::Release'      => 'release',
    'MusicBrainz::Server::Entity::ReleaseGroup' => 'release_group',
    'MusicBrainz::Server::Entity::URL'          => 'url',
    'MusicBrainz::Server::Entity::Work'         => 'work',
);

sub all_link_types
{
    return @TYPES;
}

sub _entity_class
{
    return 'MusicBrainz::Server::Entity::Relationship';
}

sub _new_from_row
{
    my ($self, $row, $obj, $matching_entity_type) = @_;
    my $entity0 = $row->{entity0};
    my $entity1 = $row->{entity1};
    my %info = (
        id => $row->{id},
        link_id => $row->{link},
        edits_pending => $row->{edits_pending},
        entity0_id => $entity0,
        entity1_id => $entity1,
    );
    if (defined $obj) {
        if ($matching_entity_type == 0 && $entity0 == $obj->id) {
            $info{entity0} = $obj;
            $info{direction} = $MusicBrainz::Server::Entity::Relationship::DIRECTION_FORWARD;
        }
        elsif ($matching_entity_type == 1 && $entity1 == $obj->id) {
            $info{entity1} = $obj;
            $info{direction} = $MusicBrainz::Server::Entity::Relationship::DIRECTION_BACKWARD;
        }
        else {
            carp "Neither relationship end-point matched the object.";
        }
    }

    return MusicBrainz::Server::Entity::Relationship->new(%info);
}

sub _check_types
{
    my ($self, $type0, $type1) = @_;

    croak 'Invalid types'
        unless exists $TYPES{$type0} && exists $TYPES{$type1} && $type0 le $type1;
}

sub get_by_id
{
    my ($self, $type0, $type1, $id) = @_;
    $self->_check_types($type0, $type1);

    my $query = "SELECT * FROM l_${type0}_${type1} WHERE id = ?";
    my $sql = Sql->new($self->c->dbh);
    my $row = $sql->select_single_row_hash($query, $id)
        or return undef;

    return $self->_new_from_row($row);
}

sub _load
{
    my ($self, $type, $target_types, @objs) = @_;
    my @target_types = @$target_types;
    my @types = map { [ sort($type, $_) ] } @target_types;
    my @rels;
    my $sql = Sql->new($self->c->dbh);
    foreach my $t (@types) {
        my $target_type = $type eq $t->[0] ? $t->[1] : $t->[0];
        my %objs_by_id = map { $_->id => $_ }
            grep { $_->relationships_by_type($target_type) == 0 } @objs;
        my @ids = keys %objs_by_id;
        next unless @ids;

        my $type0 = $t->[0];
        my $type1 = $t->[1];
        my @cond;
        my @params;
        if ($type eq $type0) {
            push @cond, "entity0 IN (" . placeholders(@ids) . ")";
            push @params, @ids;
        }
        if ($type eq $type1) {
            push @cond, "entity1 IN (" . placeholders(@ids) . ")";
            push @params, @ids;
        }
        my $query = "
            SELECT * FROM l_${type0}_${type1}
            WHERE " . join(" OR ", @cond) . "
            ORDER BY id";
        $sql->select($query, @params);
        while (1) {
            my $row = $sql->next_row_hash_ref or last;
            my $entity0 = $row->{entity0};
            my $entity1 = $row->{entity1};
            if ($type eq $type0 && exists $objs_by_id{$entity0}) {
                my $obj = $objs_by_id{$entity0};
                my $rel = $self->_new_from_row($row, $obj, 0);
                $obj->add_relationship($rel);
                push @rels, $rel;
            }
            if ($type eq $type1 && exists $objs_by_id{$entity1}) {
                my $obj = $objs_by_id{$entity1};
                my $rel = $self->_new_from_row($row, $obj, 1);
                $obj->add_relationship($rel);
                push @rels, $rel;
            }
        }
        $sql->finish;
    }
    return @rels;
}

sub load_entities
{
    my ($self, @rels) = @_;
    my %ids_by_type;
    foreach my $rel (@rels) {
        my $linktype = $rel->link->type->name;
        if ($rel->entity0_id && !defined($rel->entity0)) {
            my $type = $rel->link->type->entity0_type;
            $ids_by_type{$type} = [] if !exists($ids_by_type{$type});
            push @{$ids_by_type{$type}}, $rel->entity0_id;
        }
        if ($rel->entity1_id && !defined($rel->entity1)) {
            my $type = $rel->link->type->entity1_type;
            $ids_by_type{$type} = [] if !exists($ids_by_type{$type});
            push @{$ids_by_type{$type}}, $rel->entity1_id;
        }
    }

    my %data_by_type;
    foreach my $type (keys %ids_by_type) {
        my @ids = @{$ids_by_type{$type}};
        $data_by_type{$type} =
            $self->c->model(type_to_model($type))->get_by_ids(@ids);
    }

    foreach my $rel (@rels) {
        if ($rel->entity0_id && !defined($rel->entity0)) {
            my $type = $rel->link->type->entity0_type;
            my $obj = $data_by_type{$type}->{$rel->entity0_id};
            $rel->entity0($obj) if defined($obj);
        }
        if ($rel->entity1_id && !defined($rel->entity1)) {
            my $type = $rel->link->type->entity1_type;
            my $obj = $data_by_type{$type}->{$rel->entity1_id};
            $rel->entity1($obj) if defined($obj);
        }
    }

    my @load_ac = grep { $_->meta->find_method_by_name('artist_credit') } map { values %$_ } values %data_by_type;
    $self->c->model('ArtistCredit')->load(@load_ac);
}

sub load_subset
{
    my ($self, $types, @objs) = @_;
    my %objs_by_type;
    return unless @objs; # nothing to do
    foreach my $obj (@objs) {
        if (exists $ENTITY_CLASS_TO_TYPE{$obj->meta->name}) {
            my $type = $ENTITY_CLASS_TO_TYPE{$obj->meta->name};
            $objs_by_type{$type} = [] if !exists($objs_by_type{$type});
            push @{$objs_by_type{$type}}, $obj;
        }
    }
    my @rels;
    foreach my $type (keys %objs_by_type) {
        push @rels, $self->_load($type, $types, @{$objs_by_type{$type}});
    }
    $self->c->model('Link')->load(@rels);
    $self->c->model('LinkType')->load(map { $_->link } @rels);
    $self->load_entities(@rels);
}

sub load
{
    my ($self, @objs) = @_;
    return $self->load_subset(\@TYPES, @objs);
}

sub _generate_table_list
{
    my ($type, @end_types) = @_;
    # Generate a list of all possible type combinations
    my @types;
    @end_types = @TYPES unless @end_types;
    foreach my $t (@end_types) {
        if ($type le $t) {
            push @types, ["l_${type}_${t}", 'entity0', 'entity1'];
        }
        if ($type ge $t) {
            push @types, ["l_${t}_${type}", 'entity1', 'entity0'];
        }
    }
    return @types;
}

sub merge_entities
{
    my ($self, $type, $target_id, @source_ids) = @_;

    my $sql = Sql->new($self->c->dbh);
    foreach my $t (_generate_table_list($type)) {
        my ($table, $entity0, $entity1) = @$t;
        # Delete all relationships from the source entities,
        # which don't already exist on the target entity
        $sql->do("
            DELETE FROM $table a
            WHERE $entity0 IN (" . placeholders(@source_ids) . ") AND
                EXISTS (SELECT 1 FROM $table b WHERE $entity0 = ? AND
                    a.$entity1 = b.$entity1 AND a.link = b.link)
        ", @source_ids, $target_id);
        # Move all remaining relationships
        $sql->do("
            UPDATE $table SET $entity0 = ?
            WHERE $entity0 IN (" . placeholders(@source_ids) . ")
        ", $target_id, @source_ids);
    }
}

sub delete_entities
{
    my ($self, $type, @ids) = @_;

    my $sql = Sql->new($self->c->dbh);
    foreach my $t (_generate_table_list($type)) {
        my ($table, $entity0, $entity1) = @$t;
        $sql->do("
            DELETE FROM $table a
            WHERE $entity0 IN (" . placeholders(@ids) . ")
        ", @ids);
    }
}

sub exists
{
    my ($self, $type0, $type1, $values) = @_;
    $self->_check_types($type0, $type1);
    return $self->sql->select_single_value(
        "SELECT 1 FROM l_${type0}_${type1}
          WHERE entity0 = ? AND entity1 = ? AND link = ?",
        $values->{entity0}, $values->{entity1},
        $self->c->model('Link')->find({
            link_type_id => $values->{link_type_id},
            begin_date => $values->{begin_date},
            end_date => $values->{end_date},
            attributes => $values->{attributes},
        })
    );
}

sub insert
{
    my ($self, $type0, $type1, $values) = @_;
    $self->_check_types($type0, $type1);

    my $sql = Sql->new($self->c->dbh);
    my $row = {
        link => $self->c->model('Link')->find_or_insert({
            link_type_id => $values->{link_type_id},
            begin_date => $values->{begin_date},
            end_date => $values->{end_date},
            attributes => $values->{attributes},
        }),
        entity0 => $values->{entity0_id},
        entity1 => $values->{entity1_id},
    };
    my $id = $sql->insert_row("l_${type0}_${type1}", $row, 'id');

    return $self->_entity_class->new( id => $id );
}

sub update
{
    my ($self, $type0, $type1, $id, $values, $link) = @_;
    $self->_check_types($type0, $type1);

    my %link;
    for (qw( link_type_id begin_date end_date attributes ))
    {
        # Because we're using a "find_or_insert" instead of an update, this link
        # dict should be complete.  If a value isn't defined in $values in doesn't
        # change, so take the original value as it was stored in $link.
        $link{$_} = defined $values->{$_} ? $values->{$_} : $link->{$_};
    }

    my $sql = Sql->new($self->c->dbh);
    my $row = {};

    $row->{link} = $self->c->model('Link')->find_or_insert(\%link);
    $row->{entity0} = $values->{entity0_id} if exists $values->{entity0_id};
    $row->{entity1} = $values->{entity1_id} if exists $values->{entity1_id};

    $sql->update_row("l_${type0}_${type1}", $row, { id => $id });
}

sub delete
{
    my ($self, $type0, $type1, @ids) = @_;
    $self->_check_types($type0, $type1);

    my $sql = Sql->new($self->c->dbh);
    $sql->do("DELETE FROM l_${type0}_${type1}
              WHERE id IN (" . placeholders(@ids) . ")", @ids);
}

sub adjust_edit_pending
{
    my ($self, $type0, $type1, $adjust, @ids) = @_;
    $self->_check_types($type0, $type1);

    my $sql = Sql->new($self->c->dbh);
    my $query = "UPDATE l_${type0}_${type1}
                 SET edits_pending = edits_pending + ?
                 WHERE id IN (" . placeholders(@ids) . ")";
    $sql->do($query, $adjust, @ids);
}

__PACKAGE__->meta->make_immutable;
no Moose;
1;

=head1 NAME

MusicBrainz::Server::Data::Relationship

=head1 COPYRIGHT

Copyright (C) 2009 Lukas Lalinsky

This program is free software; you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation; either version 2 of the License, or
(at your option) any later version.

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
GNU General Public License for more details.

You should have received a copy of the GNU General Public License
along with this program; if not, write to the Free Software
Foundation, Inc., 675 Mass Ave, Cambridge, MA 02139, USA.

=cut
