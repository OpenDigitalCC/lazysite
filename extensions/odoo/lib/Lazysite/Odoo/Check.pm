package Lazysite::Odoo::Check;

# SM1369 X6, H-6 (ruling 55): WHAT `lazysite check` SAYS ABOUT THE ODOO EXTENSION.
#
# These were five functions of tools/lazysite-check.pl that knew the extension by
# name. They are the extension's own now, declared in its `hooks.checks`, and
# core calls run() for an enabled Odoo extension, through the hook loader, and
# prints each finding with its own report() - the same lines in the same order
# as before. A finding is { level => OK|WARN|FAIL, text, fix }. The extension
# installed and off is core's one line ("installed, off"); none of these runs
# then.
#
# Each reads what it read before and asks Odoo nothing: the scheduled accounts'
# expiry as odoo-status last read it (SM1161), the OOM the site loads (SM1244),
# oomd's state (SM1164 D4), the Odoo sign-in's group map (SM1160) and the read
# bindings saved at the old form default (SM1173). No key is read, shown or
# named by file.
use strict;
use warnings;
use JSON::PP ();
use POSIX    ();

# SM1244 (#376): OOM 0.37 AND EARLIER CAN SEND A WRITE AGAIN WHEN ITS ANSWER TIMED
# OUT, so a change can be made twice in Odoo. 0.38 calls such a change `unknown`
# and does not repeat it (runs-38, SM1216).
our $OOM_SAFE_RESEND = q{0.38};

# The hook: ( $docroot, $lazysite_dir ) -> [ findings ].
sub run {
    my ( $docroot, $lz ) = @_;
    my @out;
    my $say = sub { my ( $level, $text, $fix ) = @_; push @out, { level => $level, text => $text, fix => $fix } };
    scheduled_keys( $lz, $say );
    oom_version($say);
    daemon( $docroot, $lz, $say );
    site_signin( $lz, $say );
    read_caps( $docroot, $say );
    return \@out;
}

# ( $hash, 'ok' ), ( undef, 'absent' ), ( undef, 'unreadable', $! ) or
# ( undef, 'undecodable' ): absent and unreadable are different answers.
sub _read_json_state {
    my ($path) = @_;
    open my $fh, '<:raw', $path or return $!{ENOENT} ? ( undef, 'absent' ) : ( undef, 'unreadable', "$!" );
    my $raw = do { local $/; <$fh> };
    close $fh;
    my $d = eval { JSON::PP::decode_json( length( $raw // '' ) ? $raw : '{}' ) };
    return ref $d eq 'HASH' ? ( $d, 'ok' ) : ( undef, 'undecodable' );
}

sub _read_json {
    my ($path) = @_;
    my ($d)    = _read_json_state($path);
    return $d;
}

# SM1161 (L5): A SCHEDULED BINDING'S OWN ODOO KEY EXPIRES, AND NOTHING ELSE
# WOULD SAY SO UNTIL THE NIGHT'S RUN FAILED. The date is what `odoo-status` last
# read from OOM (lazysite/odoo/scheduled-expiry.json) - no call to Odoo - and the
# days left are worked out here, so a key that expired after the last read is
# still found. WARN within 14 days and when past; an expiry never read, or not
# reported for this Odoo, is said so at ok.
sub scheduled_keys {
    my ( $lz, $say ) = @_;
    my $dir = "$lz/odoo";
    my ( $sched, $st, $err ) = _read_json_state("$dir/scheduled.json");
    if ( $st eq 'unreadable' ) {
        $say->( 'WARN', "the Odoo scheduled-binding accounts cannot be read ($err), so their keys' expiry is not checked",
            'run the check as the web server user, or fix the file\'s group access' );
        return;
    }
    return unless $st eq 'ok' && %$sched;
    my $seen = _read_json("$dir/scheduled-expiry.json") || {};
    my $now  = time;
    for my $b ( sort keys %$sched ) {
        my $login = $sched->{$b}{login} // '?';
        my $e     = $seen->{$b};
        my $what  = "the Odoo key for scheduled binding '$b' (login $login)";
        if ( ref $e ne 'HASH' || ( $e->{key} // '' ) ne ( $sched->{$b}{id} // '' ) ) {
            $say->( 'OK', "$what: expiry not yet read - the Odoo status page reads it" );
            next;
        }
        unless ( defined $e->{expires_by} ) {
            $say->( 'OK', "$what: expiry not reported (" . ( $e->{expiry} // 'unknown' ) . ')' );
            next;
        }
        my $left = int( ( $e->{expires_by} - $now ) / 86400 );
        my $when = POSIX::strftime( '%Y-%m-%d', gmtime $e->{expires_by} );
        my $hint = 'issue a new key in Odoo for that login and set it again on the Odoo page '
            . "(odoo-secret-set with scheduled=$b)";
        if ( $e->{expires_by} <= $now ) {
            $say->( 'WARN', "$what has expired ($when): its scheduled runs are refused by Odoo", $hint );
        }
        elsif ( $left < 14 ) {
            $say->( 'WARN', "$what expires $when ($left day" . ( $left == 1 ? '' : 's' ) . ' left)', $hint );
        }
        else {
            $say->( 'OK', "$what expires $when ($left days left)" );
        }
    }
    return;
}

# SM1244: the OOM the site loads, asked the way any Perl asks - `require
# Odoo::Ops` on its @INC - and the file it found named.
sub oom_version {
    my ($say) = @_;
    my ( $have, $file );
    if ( eval { require Odoo::Ops::Version; 1 } ) {
        no warnings 'once';
        ( $have, $file ) = ( $Odoo::Ops::Version::VERSION, $INC{'Odoo/Ops/Version.pm'} );
    }
    elsif ( eval { require Odoo::Ops; 1 } ) {
        ( $have, $file ) = ( eval { Odoo::Ops->VERSION }, $INC{'Odoo/Ops.pm'} );
    }
    else {
        $say->( 'WARN', 'the Odoo extension is on and OOM cannot be loaded (Odoo::Ops), so every Odoo call is refused',
            'install OOM ' . $OOM_SAFE_RESEND . ' or later (libodoo-oom-perl)' );
        return;
    }
    require version;
    my $old = !defined $have || !eval { version->parse($have) >= version->parse($OOM_SAFE_RESEND) };
    unless ($old) {
        $say->( 'OK', "the Odoo extension loads OOM $have ($file)" );
        return;
    }
    $say->( 'WARN',
        'the Odoo extension is on and the OOM it loads is ' . ( $have // 'unversioned' ) . " ($file): "
            . "OOM older than $OOM_SAFE_RESEND can send a write again when its answer timed out, "
            . 'so a change can be made twice in Odoo',
        "install OOM $OOM_SAFE_RESEND or later (libodoo-oom-perl >= $OOM_SAFE_RESEND, and odoo-oom-tools "
            . 'for oomd)' );
    return;
}

# SM1164 D4: a site that sets odoo_daemon to on or required has asked for oomd.
# When it is not running a call falls back to the slower in-process path (on) or
# is refused (required), and nothing says so until a page is slow or fails: so
# this names the site, the socket it should answer on, and why it is not there
# when the supervisor knows.
sub daemon {
    my ( $docroot, $lz, $say ) = @_;
    return unless -r "$lz/odoo.conf";
    my $st = eval {
        require Lazysite::Odoo;
        require Lazysite::Odoo::Daemon;
        no warnings 'once';
        local $Lazysite::Odoo::DOCROOT = $docroot;
        Lazysite::Odoo::Daemon::status($docroot);
    };
    return unless ref $st eq 'HASH' && $st->{mode} ne 'off';
    my $where = $st->{socket_in} eq 'site'
        ? "its socket is under the site ($st->{socket})"
        : "the site path is too long for a socket, so it uses oomd's default directory ($st->{socket})";
    if ( $st->{running} ) {
        my $h = $st->{health} || {};
        $say->( 'OK', "the Odoo extension's oomd is running ($st->{name}, OOM $h->{version}, $h->{workers} workers); $where" );
        # SM1244: a call oomd answers runs in oomd's OOM, not the one the site
        # loads, so its version is asked the same question.
        require version;
        $say->( 'WARN',
            "the Odoo extension's oomd runs OOM $h->{version}: OOM older than $OOM_SAFE_RESEND can send a write "
                . 'again when its answer timed out, so a change can be made twice in Odoo',
            "install OOM $OOM_SAFE_RESEND or later (odoo-oom-tools and libodoo-oom-perl >= $OOM_SAFE_RESEND) "
                . 'and restart oomd' )
            if defined $h->{version}
            && !eval { version->parse( $h->{version} ) >= version->parse($OOM_SAFE_RESEND) };
        return;
    }
    my $level = $st->{mode} eq 'required' ? 'FAIL' : 'WARN';
    my $why
        = !$st->{installed} ? 'oomd is not installed (the odoo-oom-tools package)'
        : $st->{failed}     ? "the supervisor stopped restarting it: $st->{reason}"
        :   'the daemon extension is not running it - it must be enabled and its runtime running';
    $say->( $level,
        "the Odoo extension has odoo_daemon: $st->{mode} and oomd ($st->{name}) is not running; $why",
        ( $st->{mode} eq 'required' ? 'every Odoo call is refused until it runs' : 'Odoo calls take the slower in-process path until it runs' )
            . "; $where" );
    return;
}

# SM1160: on a site that opted in (odoo_site_signin: on) the mapping of Odoo
# groups to site groups is part of who can see what. Each entry refused is
# named: it grants nothing and is the operator's to correct. Reads the config;
# asks Odoo nothing.
sub site_signin {
    my ( $lz, $say ) = @_;
    require Lazysite::Odoo::SiteSignin;
    my $r = Lazysite::Odoo::SiteSignin::report($lz);
    return unless $r->{enabled};
    $say->( 'OK', "the Odoo sign-in is the site sign-in; $r->{mapped} Odoo group" . ( $r->{mapped} == 1 ? '' : 's' ) . ' mapped'
            . ( defined $r->{unknown_note} ? " ($r->{unknown_note})" : '' ) );
    for my $x ( @{ $r->{refused} } ) {
        $say->( 'WARN', "odoo_group_map: '$x->{xmlid} = $x->{group}' is refused and grants nothing - $x->{why}",
            'correct the entry on the Odoo page; a site group that carries a capability cannot be given by an Odoo group' );
    }
    return;
}

# SM1173: READ BINDINGS SAVED WITH THE OLD FORM DEFAULT (20 and 200 per hour, which
# the form used to save into every binding). A WARN that names the binding and
# changes nothing; whether a binding reads is the operation's own answer, and
# when OOM or the connection cannot be asked the binding is not named.
sub read_caps {
    my ( $docroot, $say ) = @_;
    my $list = eval {
        require Lazysite::Handlers;
        no warnings 'once';
        local $Lazysite::Handlers::DOCROOT = $docroot;
        Lazysite::Handlers::read_handlers();
    };
    return unless ref $list eq 'ARRAY';
    my @old = grep {
        ( $_->{type} // '' ) eq 'odoo'
            && ( $_->{rate_per_visitor_hour} // '' ) eq '20'
            && ( $_->{rate_per_hour}         // '' ) eq '200'
    } @$list;
    return unless @old;
    return unless eval { require Lazysite::Odoo; 1 };
    no warnings 'once';
    local $Lazysite::Odoo::DOCROOT = $docroot;
    for my $b ( sort { $a->{id} cmp $b->{id} } @old ) {
        my $w = eval { Lazysite::Odoo::writes_of($b) };
        next unless defined $w && !$w;
        $say->( 'WARN',
            "binding $b->{id} is a read capped at 20/200 per hour, the old form default; "
                . 'clear its two Cap fields in the manager to take 2000/20000',
            'the Handlers page: empty rate_per_visitor_hour and rate_per_hour on that binding' );
    }
    return;
}

1;
