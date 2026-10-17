package Odoo::Test::MailingFixture;

use strict;
use warnings;
use feature qw(signatures);
no warnings 'experimental::signatures';

use JSON::PP ();

use Odoo::Error;
use Odoo::Ops::Match;
use Odoo::Test::FakeOdoo;

# A fake Odoo 16 with mass_mailing: lists, contacts and their subscriptions,
# the blacklist, a mailing with the state machine and the counters Odoo
# computes from its traces, the test wizard, the two crons and the mail
# queue. It is the 16.0 source in miniature (mass_mailing/models/mailing.py,
# mailing_contact.py, mailing_trace.py, wizard/mailing_mailing_test.py,
# mail/models/mail_blacklist.py), and it keeps the facts that matter to
# the pack: `expected` is the number of traces, so 0 until a send; `total`
# is every contact of the lists; an opted-out, blacklisted or repeated
# address gets a cancelled trace and no mail; a direct send leaves the
# mailing `done`; queueing makes a cron trigger.
#
#   my ($fake, $fx) = Odoo::Test::MailingFixture->fake( series => 16 );
#   $fx->{now} = '2026-10-15 12:00:00';        # what write_date reads
#   $fx->{mail_server_down} = 1;               # mails stay outgoing
#   $fx->{test_fail} = { 'bad@example.com' => 'Connection refused' };
#   $fx->{log}                                 # the order Odoo's methods ran in
#
# The fake runs as a mailing operator would: a read that names no fields is a
# fault of the test (require_fields), and sale_invoiced_amount, the computed field
# mass_mailing_sale adds over account.move, faults for whoever reads it (its
# compute is not run as sudo here, as a user without accounting rights meets it).
# fake( operator => 1 ) also refuses the administration models the convenience
# reads touch: ir.model.data, ir.cron, ir.cron.trigger, ir.mail_server,
# ir.config_parameter and mail.mail.

my $c   = sub { { type => 'char', store => 1 } };
my $bool = sub { { type => 'boolean', store => 1 } };
my $i   = sub { { type => 'integer', store => 1 } };
my $dt  = sub { { type => 'datetime', store => 1 } };
my $m2o = sub ($rel) { { type => 'many2one', relation => $rel, store => 1 } };
my $m2m = sub ($rel) { { type => 'many2many', relation => $rel, store => 1 } };

sub fields () {
    return {
        'mailing.mailing' => {
            subject => $c->(), email_from => $c->(), reply_to => $c->(), reply_to_mode => $c->(), body_html => { type => 'html' },
            body_arch => { type => 'html' }, state => $c->(), mailing_model_id => $m2o->('ir.model'), mailing_model_real => $c->(),
            contact_list_ids => $m2m->('mailing.list'), schedule_type => $c->(), schedule_date => $dt->(), sent_date => $dt->(),
            write_date => $dt->(), create_date => $dt->(), active => $bool->(),
            # computed and not stored in Odoo 16 (total by _compute_total, the rest by _compute_statistics)
            ( map { $_ => { type => 'integer', store => 0 } } qw(total expected scheduled canceled sent delivered opened clicked replied bounced failed received_ratio opened_ratio) ),
            # what mass_mailing_sale and mass_mailing_crm add (computed, not stored): the first reads account.move
            sale_quotation_count => { type => 'integer', store => 0 }, sale_invoiced_amount => { type => 'integer', store => 0 },
            crm_lead_count => { type => 'integer', store => 0 },
        },
        'mailing.list' => { name => $c->(), active => $bool->(), contact_count => $i->(), contact_count_opt_out => $i->(),
            contact_count_blacklisted => $i->(), contact_count_email => $i->(), mailing_count => $i->(),
            subscription_ids => { type => 'one2many', relation => 'mailing.contact.subscription', relation_field => 'list_id' } },
        'mailing.contact' => { name => $c->(), email => $c->(), email_normalized => $c->(), company_name => $c->(),
            tag_ids => $m2m->('res.partner.category'), list_ids => $m2m->('mailing.list'), is_blacklisted => $bool->(),
            subscription_list_ids => { type => 'one2many', relation => 'mailing.contact.subscription', relation_field => 'contact_id' } },
        'mailing.contact.subscription' => { contact_id => $m2o->('mailing.contact'), list_id => $m2o->('mailing.list'),
            opt_out => $bool->(), unsubscription_date => $dt->() },
        'mailing.trace' => { mass_mailing_id => $m2o->('mailing.mailing'), email => $c->(), trace_status => $c->(), failure_type => $c->(),
            sent_datetime => $dt->(), open_datetime => $dt->(), links_click_datetime => $dt->(), reply_datetime => $dt->(),
            mail_mail_id => $m2o->('mail.mail'), res_id => $i->(), model => $c->() },
        'mail.blacklist' => { email => $c->(), active => $bool->(), create_date => $dt->() },
        'mail.mail' => { mailing_id => $m2o->('mailing.mailing'), state => $c->(), failure_reason => $c->(), email_to => $c->(), subject => $c->() },
        'mailing.mailing.test' => { mass_mailing_id => $m2o->('mailing.mailing'), email_to => { type => 'text' } },
        'mail.compose.message' => { composition_mode => $c->(), model => $c->(), subject => $c->(), body => { type => 'html' },
            mass_mailing_id => $m2o->('mailing.mailing'), mailing_list_ids => $m2m->('mailing.list'), email_from => $c->(),
            reply_to => $c->(), reply_to_force_new => $bool->() },
        'link.tracker' => { mass_mailing_id => $m2o->('mailing.mailing'), url => $c->(), short_url => $c->(), count => $i->() },
        'ir.cron' => { cron_name => $c->(), interval_number => $i->(), interval_type => $c->(), nextcall => $dt->(), lastcall => $dt->(), active => $bool->() },
        'ir.cron.trigger' => { cron_id => $m2o->('ir.cron'), call_at => $dt->() },
        'res.partner.category' => { name => $c->(), active => $bool->() },
        'mail.message' => { model => $c->(), res_id => $i->(), body => { type => 'html' } },
        'ir.model' => { model => $c->(), name => $c->() },
        'ir.model.data' => { module => $c->(), name => $c->(), model => $c->(), res_id => $i->() },
        'ir.mail_server' => { name => $c->(), sequence => $i->(), from_filter => $c->(), active => $bool->() },
        'ir.config_parameter' => { key => $c->(), value => $c->() },
    };
}

sub _norm_vals ($fake, $model, $vals) {
    my %v = %$vals;
    for my $k ( keys %v ) {
        my $d = $fake->{fields}{$model}{$k} or next;
        $v{$k} = $v{$k} ? 1 : 0 if $d->{type} eq 'boolean';    # the transport answers 1 and 0
    }
    return \%v;
}

# everything Odoo computes, redone from the rows
sub recompute ($fake) {
    my $fx = $fake->{mailing_fx};
    my $d  = $fake->{data};
    my %bl = map { lc $_->{email} => 1 } grep { $_->{active} } values %{ $d->{'mail.blacklist'} // {} };
    for my $ct ( values %{ $d->{'mailing.contact'} // {} } ) {
        my ($e) = Odoo::Ops::Match::norm_email( $ct->{email} );
        $ct->{email_normalized} = $e // '';
        $ct->{is_blacklisted} = $e && $bl{$e} ? 1 : 0;
    }
    my @subs = values %{ $d->{'mailing.contact.subscription'} // {} };
    # the one2many sides of a subscription, as Odoo derives them from the rows
    for my $ct ( values %{ $d->{'mailing.contact'} // {} } ) { $ct->{subscription_list_ids} = [ sort { $a <=> $b } map { $_->{id} } grep { ( $_->{contact_id} // 0 ) == $ct->{id} } @subs ] }
    for my $ct ( values %{ $d->{"mailing.contact"} // {} } ) { my %seen; $ct->{list_ids} = [ sort { $a <=> $b } grep { !$seen{$_}++ } map { $_->{list_id} } grep { ( $_->{contact_id} // 0 ) == $ct->{id} } @subs ] }
    # Odoo defaults active to true; a row inserted without it is live, as a domain on active must see it
    $_->{active} //= 1 for values %{ $d->{"mailing.mailing"} // {} };
    for my $l ( values %{ $d->{'mailing.list'} // {} } ) { $l->{subscription_ids} = [ sort { $a <=> $b } map { $_->{id} } grep { ( $_->{list_id} // 0 ) == $l->{id} } @subs ] }
    for my $l ( values %{ $d->{'mailing.list'} // {} } ) {
        my @mine = grep { ( $_->{list_id} // 0 ) == $l->{id} } @subs;
        my @cs   = map { $d->{'mailing.contact'}{ $_->{contact_id} } } grep { $d->{'mailing.contact'}{ $_->{contact_id} } } @mine;
        $l->{contact_count} = scalar @mine;
        $l->{contact_count_opt_out} = scalar grep { $_->{opt_out} } @mine;
        $l->{contact_count_blacklisted} = scalar grep { $_->{is_blacklisted} } @cs;
        $l->{contact_count_email} = scalar grep { my $s = $_; my $ct = $d->{'mailing.contact'}{ $s->{contact_id} }; $ct && length $ct->{email_normalized} && !$s->{opt_out} && !$ct->{is_blacklisted} } @mine;
        $l->{mailing_count} = scalar grep { grep { $_ == $l->{id} } @{ $_->{contact_list_ids} // [] } } values %{ $d->{'mailing.mailing'} // {} };
    }
    for my $m ( values %{ $d->{'mailing.mailing'} // {} } ) {
        my @t = grep { ( $_->{mass_mailing_id} // 0 ) == $m->{id} } values %{ $d->{'mailing.trace'} // {} };
        my %in = map { $_ => 1 } @{ $m->{contact_list_ids} // [] };
        my %cid = map { $_->{contact_id} => 1 } grep { $in{ $_->{list_id} // 0 } } @subs;
        $m->{total} = scalar keys %cid;
        my $n = sub ($code) { scalar grep { $code->($_) } @t };
        $m->{expected}  = scalar @t;
        $m->{sent}      = $n->( sub { $_[0]{sent_datetime} } );
        $m->{scheduled} = $n->( sub { ( $_[0]{trace_status} // '' ) eq 'outgoing' } );
        $m->{canceled}  = $n->( sub { ( $_[0]{trace_status} // '' ) eq 'cancel' } );
        $m->{delivered} = $n->( sub { ( $_[0]{trace_status} // '' ) =~ /^(sent|open|reply)\z/ } );
        $m->{opened}    = $n->( sub { ( $_[0]{trace_status} // '' ) =~ /^(open|reply)\z/ } );
        $m->{clicked}   = $n->( sub { $_[0]{links_click_datetime} } );
        $m->{replied}   = $n->( sub { ( $_[0]{trace_status} // '' ) eq 'reply' } );
        $m->{bounced}   = $n->( sub { ( $_[0]{trace_status} // '' ) eq 'bounce' } );
        $m->{failed}    = $n->( sub { ( $_[0]{trace_status} // '' ) eq 'error' } );
        my $base = ( $m->{expected} - $m->{canceled} ) || 1;
        $m->{received_ratio} = int( 100 * $m->{delivered} / $base );
        $m->{opened_ratio}   = int( 100 * $m->{opened} / $base );
        my $im = $d->{'ir.model'}{ $m->{mailing_model_id} || 0 };
        $m->{mailing_model_real} = $im ? ( $im->{model} eq 'mailing.list' ? 'mailing.contact' : $im->{model} ) : '';
    }
    return;
}

sub _touch ($fake, $model, $rec) {
    my $fx = $fake->{mailing_fx};
    return if $model ne 'mailing.mailing';
    $rec->{write_date} = $fx->{now};
}

# the mails of a mailing's send, as Odoo's composer makes them
sub _send ($fake, $mid) {
    my $fx = $fake->{mailing_fx};
    my $d  = $fake->{data};
    my $m  = $d->{'mailing.mailing'}{$mid};
    my %in = map { $_ => 1 } @{ $m->{contact_list_ids} // [] };
    my @subs = grep { $in{ $_->{list_id} // 0 } } values %{ $d->{'mailing.contact.subscription'} // {} };
    my %done = map { $_->{res_id} => 1 } grep { ( $_->{mass_mailing_id} // 0 ) == $mid } values %{ $d->{'mailing.trace'} // {} };
    my %by_contact;
    push @{ $by_contact{ $_->{contact_id} } }, $_ for @subs;
    my @res = grep { !$done{$_} } sort { $a <=> $b } keys %by_contact;
    Odoo::Test::FakeOdoo::_fault( 'UserError', 'There are no recipients selected.' ) if !@res;
    # an address opted out of every list it is on is opted out; one in any list it is on is not
    my ( %out, %inn );
    for my $s (@subs) {
        my $e = $d->{'mailing.contact'}{ $s->{contact_id} }{email_normalized} // '';
        $s->{opt_out} ? ( $out{$e} = 1 ) : ( $inn{$e} = 1 );
    }
    my %seen;
    for my $cid (@res) {
        my $ct = $d->{'mailing.contact'}{$cid};
        my $e  = $ct->{email_normalized} // '';
        my %tr = ( mass_mailing_id => $mid, email => $e, res_id => $cid, model => 'mailing.contact', trace_status => 'outgoing' );
        my $why = !length $e ? 'mail_email_missing' : $ct->{is_blacklisted} ? 'mail_bl' : ( $out{$e} && !$inn{$e} ) ? 'mail_optout' : $seen{$e}++ ? 'mail_dup' : undef;
        if ($why) {
            $fake->_create( 'mailing.trace', { %tr, trace_status => 'cancel', failure_type => $why } );
            next;
        }
        my $mail = $fake->_create( 'mail.mail', { mailing_id => $mid, state => 'outgoing', email_to => $e, subject => $m->{subject} } );
        my $tr   = $fake->_create( 'mailing.trace', { %tr, mail_mail_id => $mail } );
        _deliver( $fake, $mail ) if !$fx->{mail_server_down};
    }
    $m->{state} = 'done';
    $m->{sent_date} = $fx->{now};
    recompute($fake);
    return;
}

# a mail that reached the server: its trace is sent and the row goes (mass mail deletes itself)
sub _deliver ($fake, $mail_id) {
    my $fx = $fake->{mailing_fx};
    my $d  = $fake->{data};
    for my $t ( grep { ( $_->{mail_mail_id} // 0 ) == $mail_id } values %{ $d->{'mailing.trace'} } ) {
        $t->{trace_status} = 'sent';
        $t->{sent_datetime} = $fx->{now};
    }
    push @{ $fx->{delivered} }, $d->{'mail.mail'}{$mail_id}{email_to};
    delete $d->{'mail.mail'}{$mail_id};
    return;
}

sub fake ($class, %o) {
    my $fx = { now => '2026-10-15 12:00:00', base_url => 'https://odoo.example', log => [], delivered => [], %{ $o{fx} // {} } };
    my $fake = Odoo::Test::FakeOdoo->new(
        series  => $o{series} // 16,
        fields  => fields(),
        records => {
            'ir.model' => [ { id => 1, model => 'mailing.list', name => 'Mailing List' }, { id => 2, model => 'res.partner', name => 'Contact' } ],
            'ir.cron'  => [
                { id => 19, cron_name => 'Mail Marketing: Process queue', interval_number => 1, interval_type => 'days', nextcall => '2026-10-16 09:00:00', active => 1 },
                { id => 2,  cron_name => 'Mail: Email Queue Manager', interval_number => 1, interval_type => 'hours', nextcall => '2026-10-15 13:00:00', active => 1 },
            ],
            'ir.model.data' => [
                { module => 'mass_mailing', name => 'ir_cron_mass_mailing_queue', model => 'ir.cron', res_id => 19 },
                { module => 'mail', name => 'ir_cron_mail_scheduler_action', model => 'ir.cron', res_id => 2 },
            ],
            %{ $o{records} // {} },
        },
    );
    $fake->{mailing_fx} = $fx;
    $fake->{require_fields} = 1;
    $fake->unreadable_field( 'mailing.mailing', 'sale_invoiced_amount', 'Journal Entry', 'account.move',
        'Purchase/User', 'User types/Portal', 'Accounting/Accountant' );
    if ( $o{operator} ) {
        $fake->refuse_model( 'ir.model.data', 'Model Data', 'Administration/Access Rights' );
        $fake->refuse_model( $_->[0], $_->[1], 'Administration/Settings' )
            for [ 'ir.cron', 'Scheduled Actions' ], [ 'ir.cron.trigger', 'Triggered actions' ], [ 'ir.mail_server', 'Outgoing Mail Servers' ], [ 'ir.config_parameter', 'System Parameter' ], [ 'mail.mail', 'Outgoing Mails' ];
    }
    my $m = $fake->{methods};
    my $log = sub ($what) { push @{ $fx->{log} }, $what };
    # Odoo answers check_access_rights with a boolean; a mailing operator may not create partner tags
    # (fx no_tag_create turns it on for any user, the operator flag for the operator)
    $m->{'res.partner.category.check_access_rights'} = sub ( $fk, $args, $kw ) { ( $fx->{no_tag_create} || $o{operator} ) ? JSON::PP::false : JSON::PP::true };

    # create / write / unlink on every model with something computed, so the computed fields follow
    for my $model (qw(mailing.mailing mailing.list mailing.contact mailing.contact.subscription mailing.trace mail.blacklist mail.mail)) {
        $m->{"$model.create"} = sub ( $fk, $args, $kw ) {
            my $v = $args->[0];
            my @ids;
            for my $one ( ref $v eq 'ARRAY' ? @$v : $v ) {
                my $vals = _norm_vals( $fk, $model, $one );
                if ( $model eq 'mail.blacklist' ) {
                    my ($e) = Odoo::Ops::Match::norm_email( $vals->{email} );
                    Odoo::Test::FakeOdoo::_fault( 'UserError', "Invalid email address '$vals->{email}'" ) if !$e;
                    my ($have) = grep { lc $_->{email} eq $e } values %{ $fk->{data}{$model} // {} };
                    if ($have) { push @ids, $have->{id}; next }
                    $vals->{email} = $e;
                    $vals->{create_date} = $fx->{now};
                }
                if ( $model eq 'mailing.contact.subscription' ) {
                    $vals->{unsubscription_date} = $fx->{now} if $vals->{opt_out};
                    my ($dup) = grep { $_->{contact_id} == $vals->{contact_id} && $_->{list_id} == $vals->{list_id} } values %{ $fk->{data}{$model} // {} };
                    Odoo::Test::FakeOdoo::_fault( 'IntegrityError', 'A mailing contact cannot subscribe to the same mailing list multiple times.' ) if $dup;
                }
                if ( $model eq 'mailing.mailing' ) {
                    $vals = { create_date => $fx->{now}, state => 'draft', schedule_type => 'now', email_from => '"Test User" <tester@ours.example>', reply_to_mode => 'new',
                        reply_to => '"Test User" <tester@ours.example>', %$vals };
                }
                my $id = $fk->_create( $model, $vals );
                _touch( $fk, $model, $fk->{data}{$model}{$id} );
                push @ids, $id;
            }
            recompute($fk);
            return ref $v eq 'ARRAY' ? \@ids : $ids[0];
        };
        $m->{"$model.write"} = sub ( $fk, $args, $kw ) {
            my ( $ids, $vals ) = @$args;
            $vals = _norm_vals( $fk, $model, $vals );
            for my $id (@$ids) {
                my $r = $fk->{data}{$model}{$id} or Odoo::Test::FakeOdoo::_fault( 'MissingError', "record $id gone" );
                if ( $model eq 'mailing.contact.subscription' && exists $vals->{opt_out} ) {
                    $vals = { %$vals, unsubscription_date => $vals->{opt_out} ? $fx->{now} : 0 };
                }
                Odoo::Test::FakeOdoo::_fault( 'UserError', 'The list is used by an ongoing mailing' )
                    if $model eq 'mailing.list' && exists $vals->{active} && !$vals->{active} && grep { ( $_->{state} // '' ) ne 'done' && grep { $_ == $id } @{ $_->{contact_list_ids} // [] } } values %{ $fk->{data}{'mailing.mailing'} // {} };
                $fk->_assign( $model, $r, $vals );
                _touch( $fk, $model, $r );
            }
            recompute($fk);
            return 1;
        };
        $m->{"$model.unlink"} = sub ( $fk, $args, $kw ) {
            for my $id ( @{ $args->[0] } ) {
                delete $fk->{data}{$model}{$id};
                if ( $model eq 'mailing.contact' ) {
                    delete $fk->{data}{'mailing.contact.subscription'}{$_->{id}} for grep { ( $_->{contact_id} // 0 ) == $id } values %{ $fk->{data}{'mailing.contact.subscription'} // {} };
                }
                if ( $model eq 'mailing.list' ) {
                    delete $fk->{data}{'mailing.contact.subscription'}{$_->{id}} for grep { ( $_->{list_id} // 0 ) == $id } values %{ $fk->{data}{'mailing.contact.subscription'} // {} };
                    # the many2many row to a mailing cascades: the mailing keeps everything but the list
                    $_->{contact_list_ids} = [ grep { $_ != $id } @{ $_->{contact_list_ids} // [] } ] for values %{ $fk->{data}{'mailing.mailing'} // {} };
                }
                if ( $model eq 'mailing.mailing' ) {
                    # mailing.trace.mass_mailing_id is ondelete cascade (16.0 mailing_trace.py): the record of who was mailed goes with the mailing
                    delete $fk->{data}{'mailing.trace'}{$_->{id}} for grep { ( $_->{mass_mailing_id} // 0 ) == $id } values %{ $fk->{data}{'mailing.trace'} // {} };
                }
            }
            recompute($fk);
            return 1;
        };
    }
    # computed fields read as they stand right now
    for my $model (qw(mailing.mailing mailing.list mailing.contact)) {
        for my $meth (qw(read search_read)) {
            my $key = "$model.$meth";
            $m->{$key} = sub ( $fk, $args, $kw ) {
                recompute($fk);
                local $fk->{methods}{$key};
                delete $fk->{methods}{$key};
                my $r = $fk->call( 'object', 'execute_kw', 'd', 2, 'k', $model, $meth, $args, $kw );
                return $r;
            };
        }
    }

    # the state machine
    $m->{'mailing.mailing.action_put_in_queue'} = sub ( $fk, $args, $kw ) {
        for my $id ( @{ $args->[0] } ) {
            my $r = $fk->{data}{'mailing.mailing'}{$id};
            $r->{state} = 'in_queue';
            _touch( $fk, 'mailing.mailing', $r );
            $fk->_create( 'ir.cron.trigger', { cron_id => 19, call_at => $r->{schedule_date} || $fx->{now} } );
            $log->("put_in_queue $id");
        }
        return undef;
    };
    $m->{'mailing.mailing.action_cancel'} = sub ( $fk, $args, $kw ) {
        for my $id ( @{ $args->[0] } ) {
            my $r = $fk->{data}{'mailing.mailing'}{$id};
            @$r{qw(state schedule_date schedule_type)} = ( 'draft', 0, 'now' );
            _touch( $fk, 'mailing.mailing', $r );
            $log->("cancel $id");
        }
        return undef;
    };
    $m->{'mailing.mailing.action_send_mail'} = sub ( $fk, $args, $kw ) {
        for my $id ( @{ $args->[0] } ) { $log->("send_mail $id"); _send( $fk, $id ) }
        return 1;
    };
    $m->{'mail.mail.process_email_queue'} = sub ( $fk, $args, $kw ) {
        my $ids = $args->[0];
        $log->( 'process_email_queue ' . ( $ids && @$ids ? join( ',', @$ids ) : 'all' ) );
        for my $mail ( sort { $a->{id} <=> $b->{id} } grep { ( $_->{state} // '' ) eq 'outgoing' } values %{ $fk->{data}{'mail.mail'} // {} } ) {
            next if $ids && @$ids && !grep { $_ == $mail->{id} } @$ids;
            _deliver( $fk, $mail->{id} );
        }
        recompute($fk);
        return 1;
    };
    # the cron, run in the request: mailings in the queue whose schedule is due
    $m->{'ir.cron.method_direct_trigger'} = sub ( $fk, $args, $kw ) {
        $log->( 'cron_trigger ' . join( ',', @{ $args->[0] } ) );
        for my $r ( sort { $a->{id} <=> $b->{id} } values %{ $fk->{data}{'mailing.mailing'} // {} } ) {
            next if ( $r->{state} // '' ) !~ /^(in_queue|sending)\z/;
            next if $r->{schedule_date} && $r->{schedule_date} gt $fx->{now};
            _send( $fk, $r->{id} );
        }
        return 1;
    };
    # the test wizard: sends at once, deletes its mails, logs the outcome on the mailing
    $m->{'mailing.mailing.test.send_mail_test'} = sub ( $fk, $args, $kw ) {
        my $w = $fk->{data}{'mailing.mailing.test'}{ $args->[0][0] };
        my $mid = $w->{mass_mailing_id};
        $log->("send_mail_test $mid");
        my @li;
        for my $to ( split /\n/, $w->{email_to} ) {
            my ($e) = Odoo::Ops::Match::norm_email($to);
            if ( !$e ) { push @li, "<li>Mailing addresses incorrect: $to</li>"; next }
            if ( my $why = $fx->{test_fail}{$e} ) { push @li, "<li>Test mailing could not be sent to $e:<br>$why</li>"; next }
            push @{ $fx->{tested} }, { to => $e, subject => $fk->{data}{'mailing.mailing'}{$mid}{subject} };
            push @li, "<li>Test mailing successfully sent to $e</li>";
        }
        $fk->_create( 'mail.message', { model => 'mailing.mailing', res_id => $mid, body => '<ul>' . join( '', @li ) . '</ul>' } );
        return 1;
    };
    # the composer's public render of one mass mail per recipient (mass_mailing/wizard/mail_compose_message.py):
    # QWeb of the body, links made absolute, the layout around it; nothing is created and no link is shortened
    $m->{'mailing.mailing.get_base_url'} = sub ( $fk, $args, $kw ) { $fx->{base_url} };
    $m->{'mail.compose.message.get_mail_values'} = sub ( $fk, $args, $kw ) {
        my $w = $fk->{data}{'mail.compose.message'}{ $args->[0][0] };
        my %out;
        $log->('get_mail_values');
        for my $rid ( @{ $args->[1] } ) {
            my $ct = $fk->{data}{'mailing.contact'}{$rid} or Odoo::Test::FakeOdoo::_fault( 'MissingError', "contact $rid gone" );
            ( my $body = $w->{body} // '' ) =~ s{<t t-out="object\.name"/>}{$ct->{name}}g;
            $body =~ s{(href=")(/[^/"][^"]*)}{$1$fx->{base_url}$2}g;
            ( my $subject = $w->{subject} // '' ) =~ s/\{\{ object\.name \}\}/$ct->{name}/g;
            $out{$rid} = {
                subject => $subject, email_from => $w->{email_from} || '"Test User" <tester@ours.example>', reply_to => $w->{reply_to} || $w->{email_from} || 0,
                email_to => $ct->{email_normalized}, body => $body, model => 'mailing.contact', res_id => $rid, mailing_id => $w->{mass_mailing_id},
                body_html => "<html><body><div class=\"o_layout\">$body</div></body></html>",
            };
        }
        return \%out;
    };
    $m->{'mail.blacklist.message_post'} = sub ( $fk, $args, $kw ) {
        $fk->_create( 'mail.message', { model => 'mail.blacklist', res_id => $args->[0][0], body => $kw->{body} } );
        return 1;
    };
    recompute($fake);
    return wantarray ? ( $fake, $fx ) : $fake;
}

1;
