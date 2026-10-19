package Lazysite::Manager::AccountImport;

# SM1053 (inbox 2026-10-12, P-5), ruled 2026-10-12, "Operator-run import".
#
# A partner migrating a site had about 700 members to give accounts, and account
# creation is the operator's, by design (SM268: cookie-only). The ruling keeps it
# so and splits the work: the PARTNER PREPARES, THE OPERATOR APPROVES.
#
#   stage   (accounts-import-stage, any manage_users holder, either door): a list
#           of accounts - username, email, groups, and NO password - is written
#           to the staging area, lazysite/auth/import/, as one file.
#   plan    (accounts-import-plan, the operator, cookie only): the dry run - for
#           each row, what applying would do: create; update (n572: the account
#           exists, and its address or groups differ - each change listed);
#           skip; or refuse (the row is invalid); and which named groups
#           exist and will be joined, and which do not and will be left out.
#   apply   (accounts-import-apply, the operator, cookie only, confirmed by the
#           staged file's id): each new account is created with no password, its
#           email recorded, placed in the named groups that exist, and given a
#           claim link (/claim: the person sets their own password). The links are
#           returned to the operator, and mailed to each person only when the
#           operator asks at this apply (`mail`, off by default; n570). The
#           address is recorded, so /forgot also sends a person their own
#           link. Audited: one row per account and one for the apply, written by the dispatcher.
#   list    (accounts-import-list, the operator): what is staged, and by whom.
#
# The store is written through the users tool (account-approve), its owner, as
# a registration approval writes it (Plugins::action_form_submission_approve):
# the operator approves, and the operator is not bounded by the delegation
# ceiling - no actor is passed, as no actor is passed for an approval.

use strict;
use warnings;
use Exporter 'import';
use JSON::PP                  ();
use File::Path                qw(make_path);
use POSIX                     qw(strftime);
use Lazysite::Util            qw(log_event write_private_atomic);
use Lazysite::Auth::Acl       ();
use Lazysite::Auth::Settings  ();
use Lazysite::Manager::Common ();

our @EXPORT_OK = qw(stage plan apply list_staged remove);

our $MAX_ROWS = 5000;
my $USER_RE  = qr/\A[A-Za-z0-9_.-]{1,64}\z/;
my $EMAIL_RE = qr/\A[^@\s]+\@[^@\s]+\.[^@\s]+\z/;
my $ID_RE    = qr/\A[0-9]{8}-[0-9]{6}-[0-9a-f]{8}\z/;

sub _dir { return Lazysite::Auth::Acl::settings_dir() . '/import' }

sub _read_json {
    my ($f) = @_;
    open my $fh, '<:raw', $f or return undef;
    my $raw = do { local $/; <$fh> };
    close $fh;
    my $d = eval { JSON::PP::decode_json($raw) };
    return ref $d eq 'HASH' ? $d : undef;
}

# The rows, from a list of objects or from CSV text (username,email,groups with
# groups separated by ';'). ( \@rows, undef ) or ( undef, why ).
sub _rows_from {
    my ($in) = @_;
    my @rows;
    if ( ref $in->{accounts} eq 'ARRAY' ) {
        @rows = @{ $in->{accounts} };
    }
    elsif ( defined $in->{csv} && !ref $in->{csv} ) {
        my @lines = grep { /\S/ } split /\r?\n/, $in->{csv};
        my $head  = lc( shift(@lines) // '' );
        my @cols  = map { s/^\s+|\s+$//gr } split /,/, $head;
        return ( undef, 'the CSV has no username column' ) unless grep { $_ eq 'username' } @cols;
        for my $l (@lines) {
            my @v = map { s/^\s+|\s+$//gr } split /,/, $l, -1;
            my %r;
            @r{@cols} = @v;
            $r{groups} = [ grep { length } split /\s*;\s*/, ( $r{groups} // '' ) ] if exists $r{groups};
            push @rows, \%r;
        }
    }
    else {
        return ( undef, 'send "accounts": [ {username, email, groups}, ... ] or "csv": the text '
                . '(username,email,groups - groups separated by ;)' );
    }
    return ( undef, 'no accounts were given' ) unless @rows;
    return ( undef, "at most $MAX_ROWS accounts may be staged at once" ) if @rows > $MAX_ROWS;
    return ( \@rows, undef );
}

# accounts-import-stage. NO PASSWORDS: a row carrying any key that looks like
# a credential refuses the whole file, because a password a partner chose for a
# person is the thing SM268 keeps out of a partner's hands.
sub stage {
    my ( $in, %who ) = @_;
    return { ok => 0, kind => 'forbidden',
        error => 'An import is staged by a signed-in account, and no account is asking.' }
        unless length( $who{actor} // '' );
    $in = {} unless ref $in eq 'HASH';
    my ( $rows, $why ) = _rows_from($in);
    return { ok => 0, kind => 'invalid', error => "$why. Nothing was staged." } unless $rows;

    my ( @clean, @bad, %seen );
    my $n = 0;
    for my $r (@$rows) {
        $n++;
        unless ( ref $r eq 'HASH' ) { push @bad, { row => $n, error => 'not an object' }; next }
        if ( my ($k) = grep { /pass|secret|hash|credential|token/i } sort keys %$r ) {
            return { ok => 0, kind => 'invalid', row => $n,
                error => "row $n carries '$k'. An import carries no password: each person sets "
                    . 'their own through a claim link. Nothing was staged.' };
        }
        my $u = $r->{username};
        my $e = $r->{email}  // '';
        my $g = $r->{groups} // [];
        $g = [ grep { length } split /\s*[;,]\s*/, $g ] if !ref $g;
        my @err;
        push @err, 'username must be letters, digits, ., _ or - (64 at most)'
            unless defined $u && !ref $u && $u =~ $USER_RE && lc $u ne 'local';
        push @err, 'email is not an address' if ref $e || ( length $e && $e !~ $EMAIL_RE );
        push @err, 'groups is a list of group names'
            if ref $g ne 'ARRAY' || grep { ref $_ || !defined $_ || $_ !~ /\A[A-Za-z0-9_-]{1,64}\z/ } @$g;
        push @err, 'the username appears twice' if defined $u && !ref $u && $seen{$u}++;
        if (@err) { push @bad, { row => $n, ( defined $u && !ref $u ? ( username => $u ) : () ), error => join( '; ', @err ) }; next }
        # n572: a row that names no groups is kept so, and changes no existing
        # account's groups; a row that names them (even none) sets them.
        push @clean, { username => $u, ( length $e ? ( email => $e ) : () ),
            ( exists $r->{groups} ? ( groups => [@$g] ) : () ) };
    }

    my $id = strftime( '%Y%m%d-%H%M%S', gmtime ) . '-' . sprintf( '%08x', int( rand(0xffffffff) ) );
    my $dir = _dir();
    make_path($dir) unless -d $dir;
    my $file = "$dir/$id.json";
    # SM1183: created 0660 (staged accounts), not made under the umask and chmod'ed.
    my ($staged) = write_private_atomic( $file, JSON::PP->new->canonical->pretty->encode( {
                id       => $id,     staged_by => $who{actor}, staged_at => time,
                accounts => \@clean, invalid   => \@bad } ), 0660 );
    return { ok => 0, error => 'the staging area cannot be written; nothing was staged' }
        unless $staged;
    log_event( 'INFO', 'accounts-import', 'accounts staged', id => $id, user => $who{actor},
        accounts => scalar @clean, invalid => scalar @bad );
    return { ok => 1, id => $id, staged => scalar @clean, invalid => \@bad,
        note => 'Staged for the operator, who reviews a dry run in the manager (Users > Account '
            . 'import) and applies it. No account exists until then.' };
}

sub _load {
    my ($id) = @_;
    return ( undef, { ok => 0, kind => 'invalid', field => 'id', error => 'id is a staged import\'s id, as accounts-import-list gives it' } )
        unless defined $id && !ref $id && $id =~ $ID_RE;
    my $d = _read_json( _dir() . "/$id.json" );
    return ( undef, { ok => 0, kind => 'not-found', error => "no staged import '$id'" } ) unless $d;
    return ( $d, undef );
}

# accounts-import-remove (n571): a staged import is removed by the account that
# staged it, or by the operator - nobody else, whatever they hold. The file is
# the import; an applied one is its record of having run, and the trail keeps
# what it did, so removing it after the apply loses nothing the audit holds.
sub remove {
    my ( $id, %who ) = @_;
    return { ok => 0, kind => 'forbidden',
        error => 'An import is removed by a signed-in account, and no account is asking.' }
        unless length( $who{actor} // '' );
    my ( $d, $no ) = _load($id);
    return $no unless $d;
    my $by = $d->{staged_by} // '';
    return { ok => 0, kind => 'forbidden',
        error => "import $d->{id} was staged by $by: it is removed by that account or the operator" }
        unless $who{operator} || ( length $by && $by eq $who{actor} );
    unlink( _dir() . "/$d->{id}.json" )
        or return { ok => 0, error => "import $d->{id} could not be removed" };
    my $n = scalar @{ $d->{accounts} || [] };
    log_event( 'INFO', 'accounts-import', 'accounts import removed', id => $d->{id},
        user => $who{actor}, staged_by => $by );
    return { ok => 1, id => $d->{id}, removed => 1,
        change => "removed; staged by $by, $n account(s), "
            . ( $d->{applied_at} ? "applied by $d->{applied_by}" : 'not applied' ) };
}

# accounts-import-list.
sub list_staged {
    my $dir = _dir();
    my @out;
    if ( opendir my $dh, $dir ) {
        for my $f ( sort grep { /\A[0-9]{8}-[0-9]{6}-[0-9a-f]{8}\.json\z/ } readdir $dh ) {
            my $d = _read_json("$dir/$f") or next;
            push @out, { id => $d->{id}, staged_by => $d->{staged_by}, staged_at => $d->{staged_at},
                accounts => scalar @{ $d->{accounts} || [] }, invalid => scalar @{ $d->{invalid} || [] },
                ( $d->{applied_at} ? ( applied_at => $d->{applied_at}, applied_by => $d->{applied_by} ) : () ) };
        }
        closedir $dh;
    }
    return { ok => 1, imports => [ reverse @out ] };
}

# The dry run's facts: which accounts and groups exist now, and (n572) what an
# existing account has - its address, its own groups - and which groups an
# import may change: those that exist, and never an operator group (the
# `manager` flag, nesting included: SM991) or a registration group. Group
# settings that cannot be read leave no group an import may change.
sub _now {
    local $Lazysite::Auth::Settings::AUTH_DIR = Lazysite::Auth::Acl::settings_dir();
    my $acc = Lazysite::Auth::Settings::account_names();
    my $grp = Lazysite::Auth::Settings::group_names();
    $acc = {} unless ref $acc eq 'HASH';
    $grp = {} unless ref $grp eq 'HASH';
    my $set    = Lazysite::Auth::Settings::read_settings();
    my $gs     = Lazysite::Auth::Settings::read_group_settings();
    my $gs_bad = Lazysite::Auth::Settings::group_settings_unreadable() ? 1 : 0;
    my %no_change;    # group => why an import never changes it
    for my $g ( keys %$grp ) {
        if ($gs_bad) { $no_change{$g} = 'the group settings cannot be read'; next }
        if ( Lazysite::Auth::Settings::groups_are_operator($g) ) {
            $no_change{$g} = 'an operator group is never changed by an import';
            next;
        }
        $no_change{$g} = 'a registration group is never changed by an import'
            if ref $gs->{$g} eq 'HASH' && $gs->{$g}{registration};
    }
    my %have;
    for my $u ( keys %$acc ) {
        $have{$u} = {
            email    => ( ref $set->{$u} eq 'HASH' ? $set->{$u}{email} // '' : '' ),
            groups   => [ Lazysite::Auth::Settings::direct_groups($u) ],
            operator => Lazysite::Auth::Settings::account_is_operator($u),
        };
    }
    return ( $acc, $grp, \%no_change, \%have );
}

# n572: what applying would change on an existing account - [ changes ],
# [ groups refused ] - each change with the id the operator ticks
# (USER:email, USER:+GROUP, USER:-GROUP). Never a password.
sub _changes {
    my ( $r, $have, $grp, $no_change ) = @_;
    my $u = $r->{username};
    my ( @ch, @refused );
    if ( length( $r->{email} // '' ) && lc $r->{email} ne lc( $have->{email} // '' ) ) {
        push @ch, { id => "$u:email", field => 'email', from => $have->{email} // '', to => $r->{email} };
    }
    return ( \@ch, \@refused ) unless ref $r->{groups} eq 'ARRAY';
    my %want = map { $_ => 1 } @{ $r->{groups} };
    my %own  = map { $_ => 1 } @{ $have->{groups} || [] };
    for my $g ( sort keys %want ) {
        if ( !$grp->{$g} ) { push @refused, { group => $g, why => 'the group does not exist' } }
        elsif ( $no_change->{$g} ) { push @refused, { group => $g, why => $no_change->{$g} } }
        elsif ( !$own{$g} ) { push @ch, { id => "$u:+$g", field => 'group-add', group => $g } }
    }
    for my $g ( sort keys %own ) {
        next if $want{$g} || $no_change->{$g} || !$grp->{$g};
        push @ch, { id => "$u:-$g", field => 'group-remove', group => $g };
    }
    return ( \@ch, \@refused );
}

# accounts-import-plan: what applying would do, row by row. Nothing is written.
sub plan {
    my ($id) = @_;
    my ( $d, $no ) = _load($id);
    return $no unless $d;
    my ( $acc, $grp, $no_change, $have ) = _now();
    my ( @rows, %count, %unknown );
    for my $r ( @{ $d->{accounts} || [] } ) {
        my $u   = $r->{username};
        my %row = ( username => $u, ( $r->{email} ? ( email => $r->{email} ) : () ) );
        if ( !$acc->{$u} ) {
            # n580: a new account never joins an operator or a registration
            # group either (the rule an update has had since n572); a row naming
            # only such groups still creates the account, in none.
            my @join = grep   { $grp->{$_} && !$no_change->{$_} } @{ $r->{groups} || [] };
            my @miss = grep   { !$grp->{$_} } @{ $r->{groups}                     || [] };
            my @refused = map { { group => $_, why => $no_change->{$_} } }
                grep { $grp->{$_} && $no_change->{$_} } @{ $r->{groups} || [] };
            $unknown{$_}++ for @miss;
            $count{create}++;
            push @rows, { %row, action => 'create', groups => \@join,
                ( @miss    ? ( groups_missing => \@miss )    : () ),
                ( @refused ? ( groups_refused => \@refused ) : () ) };
            next;
        }
        # n572: an operator's own account is changed on the Users page, never by
        # a file a partner prepared - its address is where its reset link goes.
        if ( $have->{$u}{operator} ) {
            $count{skip}++;
            push @rows, { %row, action => 'skip', why => 'an operator account is not changed by an import' };
            next;
        }
        my ( $ch, $refused ) = _changes( $r, $have->{$u}, $grp, $no_change );
        $unknown{ $_->{group} }++ for grep { $_->{why} =~ /does not exist/ } @$refused;
        my $do = @$ch ? 'update' : 'skip';
        $count{$do}++;
        push @rows, { %row, action => $do,
            ( @$ch ? ( changes => $ch ) : ( why => 'the account exists and nothing differs' ) ),
            ( @$refused ? ( groups_refused => $refused ) : () ) };
    }
    return { ok => 1, id => $d->{id}, staged_by => $d->{staged_by}, staged_at => $d->{staged_at},
        ( $d->{applied_at} ? ( applied_at => $d->{applied_at} ) : () ),
        create => $count{create} // 0, update => $count{update} // 0, skip => $count{skip} // 0,
        invalid => $d->{invalid} || [], groups_missing => [ sort keys %unknown ], rows => \@rows };
}

# n570 (SM1053, "mailed only if the operator chooses"): mail one new account its
# claim link, at the address its row carried and the account now records. The
# site's one mail path (Notify::send_mail: the Form SMTP extension and the
# per-hour bound, mail.per_hour), so an import is held to the same bound as
# every other mail the site sends to an account. Returns '' when it was sent, or
# why not - which the caller puts on the row; it never stops the apply.
sub _mail_claim {
    my ( $user, $email, $res ) = @_;
    return 'the row carries no address' unless length( $email // '' );
    require Lazysite::Mail;
    my ( $to, $bad ) = Lazysite::Mail::one_address($email);
    return "the address is refused - $bad" unless defined $to;
    require Lazysite::Notify;
    my $docroot = $Lazysite::Manager::Common::DOCROOT;
    # The link is absolute or it is not sent: a bare path in a mail is not a
    # link, and guessing a host for a credential-bearing URL could send the
    # person to the wrong one (SM863).
    my $link = $res->{url} // '';
    if ( $link !~ m{\A\w+://} ) {
        my $base = Lazysite::Notify::site_base($docroot);
        $link = ( $base =~ m{\A\w+://[^/\s]+} && length( $res->{path} // '' ) ) ? $base . $res->{path} : '';
    }
    return 'the site has no absolute address for the link (set site_url), so it was not mailed'
        unless length $link;
    return Lazysite::Notify::send_mail(
        $docroot,
        to      => $to,
        subject => 'Set your password',
        what    => 'claim link',
        text    => "An account '$user' has been made for you.\n\n"
            . "Open this one-time link (it expires in 24 hours) to set your password:\n\n"
            . "$link\n\n"
            . "If it has expired, use \"forgot password\" with this address to get a new one." );
}

# n572: how a change reads in the trail and on the page - never the address.
sub _said {
    my ($c) = @_;
    return 'address changed'    if $c->{field} eq 'email';
    return "joined $c->{group}" if $c->{field} eq 'group-add';
    return "left $c->{group}"   if $c->{field} eq 'group-remove';
    return 'changed';
}

# n572: make the ticked changes of one planned update, through the users tool -
# the address with settings-set (the one writer of it), a group with group-add
# or group-remove. Never a password. Leaving a group ends no session: groups are
# read fresh on every request (SEC-2026-07 M5), so the account loses the
# group's doors on its next request and keeps its own (SM1070's probe,
# t/integration/243); SM1040 signs sessions out on a changed CREDENTIAL, and an
# import changes none.
sub _update {
    my ( $r, $tick ) = @_;
    my ( @applied, @done, @failed );
    for my $c ( grep { $tick->{ $_->{id} } } @{ $r->{changes} || [] } ) {
        my %req
            = $c->{field} eq 'email'
            ? ( action => 'settings-set', key => 'email', value => $c->{to} )
            : ( action => $c->{field}, group => $c->{group} );
        my $res = Lazysite::Manager::Common::users_api( { %req, username => $r->{username} } ) || {};
        if ( $res->{ok} ) { push @applied, $c->{id}; push @done, $c; next }
        push @failed, { %$c, username => $r->{username}, error => $res->{error} // 'not made' };
    }
    return { username => $r->{username}, applied => \@applied, failed => \@failed, applied_changes => \@done };
}

# accounts-import-apply: the plan, carried out. confirm must repeat the id.
sub apply {
    my ( $id, $confirm, %who ) = @_;
    return { ok => 0, kind => 'forbidden', error => 'An import is applied by the operator.' }
        unless $who{operator} && length( $who{actor} // '' );
    my ( $d, $no ) = _load($id);
    return $no unless $d;
    return { ok => 0, kind => 'invalid', field => 'confirm',
        error => "confirm must repeat the import's id ($d->{id}); nothing was created" }
        unless defined $confirm && !ref $confirm && $confirm eq $d->{id};
    return { ok => 0, kind => 'conflict', error => "this import was applied on "
            . strftime( '%Y-%m-%d %H:%M', gmtime $d->{applied_at} ) . " by $d->{applied_by}" }
        if $d->{applied_at};

    # n572: the changes to existing accounts the operator ticked, by the ids the
    # plan shows. None ticked, none made.
    my $ticks = $who{updates} // [];
    return { ok => 0, kind => 'invalid', field => 'updates',
        error => 'updates is a list of the change ids the plan shows (USER:email, USER:+GROUP, '
            . 'USER:-GROUP); nothing was created' }
        if ref $ticks ne 'ARRAY' || grep { !defined $_ || ref $_ } @$ticks;
    my %tick = map { $_ => 1 } @$ticks;

    my $p = plan($id);
    my ( @created, @skipped, @failed, @updated, %offered );
    for my $r ( @{ $p->{rows} || [] } ) {
        $offered{ $_->{id} } = 1 for @{ $r->{changes} || [] };
        if ( $r->{action} eq 'update' ) {
            my $u = _update( $r, \%tick );
            if ( @{ $u->{applied} } || @{ $u->{failed} } ) { push @updated, $u }
            else { push @skipped, { username => $r->{username}, why => 'no change was ticked' } }
            next;
        }
        if ( $r->{action} ne 'create' ) { push @skipped, { username => $r->{username}, why => $r->{why} }; next }
        # The groups the plan found to exist, and only those - never the
        # registration groups an approval otherwise falls back to.
        my $res = Lazysite::Manager::Common::users_api( {
                action => 'account-approve', username => $r->{username},
                groups => [ @{ $r->{groups} || [] } ],
                ( $r->{email} ? ( email => $r->{email} ) : () ) } ) || {};
        unless ( $res->{ok} ) {
            push @failed, { username => $r->{username}, error => $res->{error} // 'not created' };
            next;
        }
        my @placed   = @{ $res->{group}    || [] };
        my @unplaced = @{ $res->{unplaced} || [] };
        push @created, { username => $r->{username}, groups => \@placed,
            ( @unplaced ? ( unplaced => \@unplaced ) : () ),
            claim_path => $res->{path}, ( $res->{url} ? ( claim_url => $res->{url} ) : () ) };
        if ( $who{mail} ) {
            my $why = _mail_claim( $r->{username}, $r->{email}, $res );
            $created[-1]{ length $why ? 'mail_error' : 'mailed' } = length $why ? $why : 1;
        }
    }
    my $mailed    = grep      { $_->{mailed} } @created;
    my $unmailed  = grep      { defined $_->{mail_error} } @created;
    my @unmatched = sort grep { !$offered{$_} } keys %tick;
    my $n_changes = 0;
    $n_changes += @{ $_->{applied} } for @updated;
    my @change_failed = map { @{ $_->{failed} } } @updated;
    # n572: one audit row per change made to an existing account, or tried and
    # not made - the address change named, the address not (SM877).
    my @upd_audit;
    for my $u (@updated) {
        push @upd_audit, [ 'accounts-import-update', $u->{username}, 1, "accounts import $d->{id}: " . _said($_) ]
            for @{ delete $u->{applied_changes} };
        push @upd_audit, [ 'accounts-import-update', $u->{username}, 0,
            "accounts import $d->{id}: " . _said($_) . " not made - $_->{error}" ]
            for @{ $u->{failed} };
    }

    # Marked applied, so a second apply cannot run it again.
    my $f = _dir() . "/$d->{id}.json";
    $d->{applied_at} = time;
    $d->{applied_by} = $who{actor};
    $d->{result} = { created => [ map { $_->{username} } @created ], failed => \@failed,
        ( @updated ? ( updated => [ map { { username => $_->{username}, applied => $_->{applied} } } @updated ] ) : () ) };
    if ( open my $fh, '>:raw', "$f.tmp.$$" ) {
        print {$fh} JSON::PP->new->canonical->pretty->encode($d);
        close $fh;
        rename "$f.tmp.$$", $f;
    }
    log_event( 'INFO', 'accounts-import', 'accounts import applied', id => $d->{id},
        user => $who{actor}, created => scalar @created, skipped => scalar @skipped,
        failed => scalar @failed, ( $who{mail} ? ( mailed => $mailed, not_mailed => $unmailed ) : () ) );
    return { ok => ( @failed || @change_failed ? 0 : 1 ),
        ( @failed || @change_failed ? ( kind => 'partial',
                error => scalar(@failed) . ' account(s) could not be created and '
                    . scalar(@change_failed) . ' change(s) could not be made; see failed and updated' ) : () ),
        id => $d->{id}, created => \@created, skipped => \@skipped, failed => \@failed,
        updated => \@updated, ( @unmatched ? ( unmatched => \@unmatched ) : () ),
        # SM1111 (0.15.7 test plan U9): "An import apply reported 'mailed 3, not
        # mailed 0' while the same site's sendmail could deliver nothing". `sent`
        # (kept: the key is part of the reply) counts mails the transport accepted,
        # and acceptance is not delivery - the reply says so where it is read.
        ( $who{mail} ? ( mail => { sent => $mailed, not_sent => $unmailed,
                    meaning => 'sent counts mails handed to the mail transport; delivery is not confirmed' } ) : () ),
        # One audit row per account (the dispatcher writes them; the users tool
        # writes none on its API).
        _audit_rows => [
            ( map { [ 'user-account-approve', $_->{username}, 1,
                        "accounts import $d->{id}"
                            . ( @{ $_->{groups} } ? '; placed in ' . join( ',', @{ $_->{groups} } ) : '; no group' ) ] }
                    @created ),
            ( map { [ 'user-account-approve', $_->{username}, 0, "accounts import $d->{id}: $_->{error}" ] }
                    @failed ),
            # n570: one row per claim link the operator asked to be mailed -
            # sent, or why not. The account is named and the address is not
            # (SM877: the trail is not a list of addresses).
            ( map { [ 'accounts-import-mail', $_->{username}, ( $_->{mailed} ? 1 : 0 ),
                        "accounts import $d->{id}: "
                            . ( $_->{mailed} ? 'claim link handed to the mail transport' : "claim link not handed over - $_->{mail_error}" ) ] }
                grep { $_->{mailed} || defined $_->{mail_error} } @created ),
            @upd_audit ],
        change => 'created ' . scalar(@created) . ', skipped ' . scalar(@skipped)
            . ', failed ' . scalar(@failed)
            . ( @updated ? '; updated ' . scalar(@updated) . " ($n_changes change(s))" : '' )
            . ( $who{mail} ? "; handed to the mail transport $mailed, not handed over $unmailed" : '' ),
        note => 'Each new account has no password: send each person their claim link, or tell them '
            . 'to use "forgot password" with the address recorded - it sends them their own.' };
}

1;
