package MusicBrainz::Server::Controller::Role::Delete;
use MooseX::Role::Parameterized -metaclass => 'MusicBrainz::Server::Controller::Role::Meta::Parameterizable';

parameter 'edit_type' => (
    isa => 'Int',
    required => 1
);

parameter 'create_edit_type' => (
    isa => 'Int',
    required => 0
);

role {
    my $params = shift;
    my %extra = @_;

    $extra{consumer}->name->config(
        action => {
            delete => { Chained => 'load', Edit => undef }
        },
        delete_edit_type => $params->edit_type,
        ($params->create_edit_type ? (create_edit_type => $params->create_edit_type) : ())
    );

    after 'show' => sub {
        my ($self, $c) = @_;
        my $entity_name = $self->{entity_name};
        my $entity = $c->stash->{ $entity_name };
        $c->stash(
            can_delete => $c->model($self->{model})->can_delete($entity->id)
        );
    };

    method 'delete' => sub {
        my ($self, $c) = @_;
        my $entity_name = $self->{entity_name};
        my $edit_entity = $c->stash->{ $entity_name };
        if ($c->model($self->{model})->can_delete($edit_entity->id)) {
            $c->stash( can_delete => 1 );
            # find a corresponding add edit and cancel instead, if applicable (MBS-1397)
            my $create_edit_type = $self->{create_edit_type};
            my $edit = $c->model('Edit')->find_creation_edit($entity_name, $create_edit_type, $edit_entity);
            if ($edit && $edit->can_cancel($c->user)) {
                $c->stash->{edit} = $edit;
                $c->forward('/edit/cancel', [ $edit->id ]);
            } else {
                $self->edit_action($c,
                    form        => 'Confirm',
                    form_args   => { requires_edit_note => 1 },
                    type        => $params->edit_type,
                    item        => $edit_entity,
                    edit_args   => { to_delete => $edit_entity },
                    on_creation => sub {
                        my $edit = shift;
                        my $url = $edit->is_open
                            ? $c->uri_for_action($self->action_for('show'), [ $edit_entity->gid ])
                            : $c->uri_for_action('/search/search');
                        $c->response->redirect($url);
                    },
                );
            }
        }
    };
};

1;
