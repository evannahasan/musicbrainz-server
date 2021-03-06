/*
 * @flow
 * Copyright (C) 2018 MetaBrainz Foundation
 *
 * This file is part of MusicBrainz, the open internet music database,
 * and is licensed under the GPL version 2, or (at your option) any
 * later version: http://www.gnu.org/licenses/gpl-2.0.txt
 */

import React from 'react';

import {withCatalystContext} from '../../../context';
import {l} from '../../../static/scripts/common/i18n';
import formatUserDate from '../../../utility/formatUserDate';

type Props = {|
  +$c: CatalystContextT,
  +entity: CoreEntityT,
|};

const LastUpdated = ({$c, entity}: Props) => (
  <p className="lastupdate">
    {l('Last updated on {date}', {
      date: formatUserDate($c.user, entity.last_updated),
    })}
  </p>
);

export default withCatalystContext(LastUpdated);
