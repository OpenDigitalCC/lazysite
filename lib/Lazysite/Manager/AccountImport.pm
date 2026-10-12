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
#           each row, what applying would do: create, skip (the account exists),
#           or refuse (the row is invalid); and which named groups exist and will
#           be joined, and which do not and will be left out.
#   apply   (accounts-import-apply, the operator, cookie only, confirmed by the
#           staged file's id): each new account is created with no password, its
#           email recorded, placed in the named groups that exist, and given a
#           claim link (/claim: the person sets their own password). The links are
#           returned to the operator; nothing is mailed by this - the address is
#           recorded, so /forgot sends a person their own link. Audited: one
#           row per account and one for the apply, written by the dispatcher.
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
use Lazysite::Util            qw(log_event);
use Lazysite::Auth::Acl       ();
use Lazysite::Auth::Settings  ();
use Lazysite::Manager::Common ();

our @EXPORT_OK = qw(stage plan apply list_staged);

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
            $r{groups} = [ grep { length } split /\s*;\s*/, ( $r{groups} // '' ) ];
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
        push @clean, { username => $u, ( length $e ? ( email => $e ) : () ), groups => [@$g] };
    }

    my $id = strftime( '%Y%m%d-%H%M%S', gmtime ) . '-' . sprintf( '%08x', int( rand(0xffffffff) ) );
    my $dir = _dir();
    make_path($dir) unless -d $dir;
    my $file = "$dir/$id.json";
    my $tmp  = "$file.tmp.$$";
    open my $fh, '>:raw', $tmp
        or return { ok => 0, error => 'the staging area cannot be written; nothing was staged' };
    chmod 0o660, $tmp;
    print {$fh} JSON::PP->new->canonical->pretty->encode( {
            id       => $id,     staged_by => $who{actor}, staged_at => time,
            accounts => \@clean, invalid   => \@bad } );
    close $fh;
    rename $tmp, $file
        or return { ok => 0, error => 'the staging area cannot be written; nothing was staged' };
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

# The dry run's facts: which accounts and groups exist now.
sub _now {
    local $Lazysite::Auth::Settings::AUTH_DIR = Lazysite::Auth::Acl::settings_dir();
    my $acc = Lazysite::Auth::Settings::account_names();
    my $grp = Lazysite::Auth::Settings::group_names();
    return ( ( ref $acc eq 'HASH' ? $acc : {} ), ( ref $grp eq 'HASH' ? $grp : {} ) );
}

# accounts-import-plan: what applying would do, row by row. Nothing is written.
sub plan {
    my ($id) = @_;
    my ( $d, $no ) = _load($id);
    return $no unless $d;
    my ( $acc, $grp ) = _now();
    my ( @rows, %count, %unknown );
    for my $r ( @{ $d->{accounts} || [] } ) {
        my @join = grep { $grp->{$_} } @{ $r->{groups}  || [] };
        my @miss = grep { !$grp->{$_} } @{ $r->{groups} || [] };
        $unknown{$_}++ for @miss;
        my $do = $acc->{ $r->{username} } ? 'skip' : 'create';
        $count{$do}++;
        push @rows, { username => $r->{username}, ( $r->{email} ? ( email => $r->{email} ) : () ),
            action => $do, ( $do eq 'skip' ? ( why => 'the account exists' ) : () ),
            groups => \@join, ( @miss ? ( groups_missing => \@miss ) : () ) };
    }
    return { ok => 1, id => $d->{id}, staged_by => $d->{staged_by}, staged_at => $d->{staged_at},
        ( $d->{applied_at} ? ( applied_at => $d->{applied_at} ) : () ),
        create => $count{create} // 0, skip            => $count{skip} // 0,
        invalid => $d->{invalid} || [], groups_missing => [ sort keys %unknown ], rows => \@rows };
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

    my $p = plan($id);
    my ( @created, @skipped, @failed );
    for my $r ( @{ $p->{rows} || [] } ) {
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
    }

    # Marked applied, so a second apply cannot run it again.
    my $f = _dir() . "/$d->{id}.json";
    $d->{applied_at} = time;
    $d->{applied_by} = $who{actor};
    $d->{result} = { created => [ map { $_->{username} } @created ], failed => \@failed };
    if ( open my $fh, '>:raw', "$f.tmp.$$" ) {
        print {$fh} JSON::PP->new->canonical->pretty->encode($d);
        close $fh;
        rename "$f.tmp.$$", $f;
    }
    log_event( 'INFO', 'accounts-import', 'accounts import applied', id => $d->{id},
        user   => $who{actor}, created => scalar @created, skipped => scalar @skipped,
        failed => scalar @failed );
    return { ok => ( @failed ? 0 : 1 ), ( @failed ? ( kind => 'partial',
                error => scalar(@failed) . ' account(s) could not be created; see failed' ) : () ),
        id => $d->{id}, created => \@created, skipped => \@skipped, failed => \@failed,
        # One audit row per account (the dispatcher writes them; the users tool
        # writes none on its API).
        _audit_rows => [
            ( map { [ 'user-account-approve', $_->{username}, 1,
                        "accounts import $d->{id}"
                            . ( @{ $_->{groups} } ? '; placed in ' . join( ',', @{ $_->{groups} } ) : '; no group' ) ] }
                    @created ),
            ( map { [ 'user-account-approve', $_->{username}, 0, "accounts import $d->{id}: $_->{error}" ] }
                    @failed ) ],
        change => 'created ' . scalar(@created) . ', skipped ' . scalar(@skipped)
            . ', failed ' . scalar(@failed),
        note => 'Each new account has no password: send each person their claim link, or tell them '
            . 'to use "forgot password" with the address recorded - it sends them their own.' };
}

1;
