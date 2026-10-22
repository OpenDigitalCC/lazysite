#!/usr/bin/perl
# SM352: the processor's copy of the security header set must match the module.
#
# WHY THE FACT EXISTS TWICE. Lazysite::SecurityHeaders owns the set. The render
# path in lazysite-processor.pl cannot call it - the processor loads no Lazysite
# modules (ADR 0001) - so it carries its own copy, exactly as _acl_allows_read
# copies Auth::Acl and the private-store path is copied into install.pl. This
# pins the pair, in the same treatment t/lint/51 gives that one.
#
# BY VALUE, NOT BY TEXT. The two are written differently, so this evaluates
# both and compares the header lines they produce. A copy that drifts in the
# max-age, drops a denied capability or reorders the set fails here. (Until
# SM1266 the processor spelled the Permissions-Policy out; since a page may ask
# for any feature, both build it from their list, and the DEFAULT is pinned
# below as the literal line it has always been.)
#
# WHAT IT PROTECTS. The reason SM352 exists at all is a header set maintained by
# repetition: four response paths each wrote their own list, three of them
# shorter, and the field probe that measured the homepage reported all three
# headers correct while every stylesheet and SVG the processor served carried one
# of them. Consolidating fixed today; this is what stops it recurring.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use lib "$FindBin::Bin/../../lib";
use Digest::SHA               qw(sha256);
use File::Temp                qw(tempdir);
use File::Path                qw(make_path);
use MIME::Base64              qw(encode_base64);
use TestHelper                qw(repo_root);
use Lazysite::SecurityHeaders ();

my $root = repo_root();

# SM944 S12: the copy is in the processor's output part.
my $src = do {
    open my $fh, '<', "$root/lazysite-processor/output.pm" or die $!;
    local $/;
    <$fh>;
};

# The processor is the script and its parts: a response path in any of them is
# a response path of the processor (SM944).
my @PROCESSOR = ( 'lazysite-processor.pl',
    map { s{\A\Q$root/\E}{}r } sort glob("$root/lazysite-processor/*.pm") );

# A body with the shapes that actually decide the answer: two distinct inline
# scripts, one REPEAT (which must collapse to a single hash rather than being
# listed twice), one <script src> (covered by 'self', and hashing it would
# produce a hash of the empty string that permits every empty script on the
# page), and a body with the characters a naive copy would trim.
my $FIXTURE = <<'HTML';
<html><head>
<script>var a = 1;  </script>
<script src="/assets/lazysite-chrome.js"></script>
<script>
  (function(){ document.title = "x"; })();
</script>
<script>var a = 1;  </script>
</head><body>hello</body></html>
HTML

# The extracted copy reads this to find lazysite.conf. Given a value up front so
# the subtests that do not care about the mode do not emit uninitialised-value
# warnings on every call - noise that would hide a real warning later. Pointing
# at a path that does not exist is deliberate: _conf_value returns undef, which
# is the "no conf" case, which is report-only.
{
    no warnings 'once';    ## no critic (ProhibitNoWarnings)
    $ProcessorHeadersUnderTest::LAZYSITE_DIR = '/nonexistent-for-this-test';
}

subtest 'the processor carries the copy, and it agrees' => sub {
    my $pkg = 'ProcessorHeadersUnderTest';
    for my $name (
        qw(_security_headers _inline_script_hashes _content_security_policy _csp_mode _conf_value _is_manager_request
        _csp_allow _csp_origin_ok _pp_denied _pp_page_may_ask)
        )
    {
        my ($sub) = $src =~ /(\nsub \Q$name\E \{.*?\n\}\n)/s;
        ok( $sub, "the processor's output part carries its own $name" ) or return;
        # _conf_value reads $LAZYSITE_DIR, a package global in the processor's
        # own main::. Declared here so the extracted copy compiles under strict
        # in its own package - and so the fixture below can point it at a
        # temporary conf.
        eval "package $pkg; use Digest::SHA qw(sha256); "
            . "use MIME::Base64 qw(encode_base64); our \$LAZYSITE_DIR; $sub 1;"
            or do { fail("could not evaluate $name: $@"); return };
    }

    for my $https ( 0, 1 ) {
        for my $html ( undef, $FIXTURE ) {
            local $ENV{HTTPS} = $https ? 'on' : '';
            my @module = Lazysite::SecurityHeaders::security_headers(
                https => $https,
                ( defined $html ? ( html => 1, script_hashes =>
                            [ Lazysite::SecurityHeaders::inline_script_hashes($html) ] ) : () ),
            );
            my @copy = ProcessorHeadersUnderTest::_security_headers(
                ( defined $html ? ( html => $html ) : () ) );
            is_deeply( \@copy, \@module,
                sprintf( '%s, %s',
                    $https        ? 'over TLS'                : 'over plain HTTP',
                    defined $html ? 'HTML with inline script' : 'no body' ) )
                or diag( "module:    @module\n"
                    . "processor: @copy\n"
                    . 'The engine would answer one set on the front door and '
                    . 'another on every page it renders.' );
        }
    }
};

subtest 'the two agree on every CSP mode, including a typo' => sub {
    # SM380. The processor reads the mode from lazysite.conf and the module
    # takes it as an argument, so they cannot be compared without giving each
    # its own input. What must match is the DECISION: which header name, or
    # none - and that a value neither recognises falls to report-only rather
    # than off, since a typo silently disabling a security header is the
    # direction SM356 found failing open.
    my $dir = tempdir( CLEANUP => 1 );
    make_path("$dir/lazysite");
    local $ProcessorHeadersUnderTest::LAZYSITE_DIR = "$dir/lazysite";

    for my $case ( [ '', 'report-only' ], [ 'report-only', 'report-only' ],
        [ 'enforce', 'enforce' ], [ 'off', 'off' ], [ 'wibble', 'report-only' ] )
    {
        my ( $written, $want ) = @$case;
        open my $cf, '>', "$dir/lazysite/lazysite.conf" or die $!;
        print {$cf} ( length $written ? "csp: $written\n" : "site_name: x\n" );
        close $cf;

        my $proc = ProcessorHeadersUnderTest::_csp_mode();
        my $mod  = Lazysite::SecurityHeaders::csp_mode(
            length $written ? $written : undef );
        is( $proc, $want, "processor reads '$written' as $want" );
        is( $mod,  $want, "and the module agrees" );
    }
};

subtest 'P16: the allow-lists reach the policy alike, and never the manager' => sub {
    # The processor reads the lists through resolve_site_vars (the site's, or
    # the serving domain's override); the module takes them as an argument. So
    # the processor's reader is given a stub site and the module the lists it
    # should have read, and the header lines must be the same.
    no warnings 'once';    ## no critic (ProhibitNoWarnings)
    my %site = ( csp_script_src => 'https://ads.example.com, nonsense',
        csp_connect_src => 'https://ads.example.com', csp_img_src => "'unsafe-inline' https://*.img.example.com",
        csp_frame_src => 'https://video.example.com:8443' );
    local *ProcessorHeadersUnderTest::resolve_site_vars = sub { return %site };
    local *ProcessorHeadersUnderTest::log_event         = sub { return };
    my %want = ( script => ['https://ads.example.com'], connect => ['https://ads.example.com'],
        img => ['https://*.img.example.com'], frame => ['https://video.example.com:8443'] );
    local $ENV{HTTPS}        = '';
    local $ENV{REDIRECT_URL} = '/page';
    my @copy   = ProcessorHeadersUnderTest::_security_headers( html => $FIXTURE );
    my @module = Lazysite::SecurityHeaders::security_headers( html => 1,
        script_hashes => [ Lazysite::SecurityHeaders::inline_script_hashes($FIXTURE) ], csp_allow => \%want );
    is_deeply( \@copy, \@module, 'a site page: the same lines, with the lists' ) or diag("@copy\n@module");
    my ($csp) = grep {/^Content-Security-Policy/} @copy;
    like( $csp, qr{script-src 'self' https://ads\.example\.com 'sha256-}, 'the origin sits before the hashes' );
    unlike( $csp, qr/nonsense|unsafe-inline' https/, 'and what is not an origin is left out' );

    local $ENV{REDIRECT_URL} = '/manager/';
    my ($mgr) = grep {/^Content-Security-Policy/} ProcessorHeadersUnderTest::_security_headers( html => $FIXTURE );
    unlike( $mgr, qr/ads\.example\.com/, 'the manager carries none of them' );
};

subtest 'the manager is never enforced, whatever the site is set to' => sub {
    # SM380. A CSP hash covers a <script> BLOCK and not an inline event-handler
    # ATTRIBUTE, and the manager's pages carry 186 of those - 59 in static
    # markup, 127 generated inside JS strings with interpolated arguments. So
    # enforcing on the manager stops an operator's controls firing, silently, in
    # a browser, where nothing in this suite can see it.
    #
    # Report-only there rather than a looser manager policy: 'unsafe-inline'
    # would break nothing either and would weaken the one surface where an
    # injection reaches an operator's session.
    my $dir = tempdir( CLEANUP => 1 );
    make_path("$dir/lazysite");
    open my $cf, '>', "$dir/lazysite/lazysite.conf" or die $!;
    print {$cf} "csp: enforce\n";
    close $cf;
    local $ProcessorHeadersUnderTest::LAZYSITE_DIR = "$dir/lazysite";

    my $html = '<html><body>x</body></html>';

    {
        local $ENV{REDIRECT_URL} = '/';
        my @h = ProcessorHeadersUnderTest::_security_headers( html => $html );
        ok( ( grep { /^Content-Security-Policy:/ } @h ),
            'a site page under csp: enforce is ENFORCED' );
    }

    for my $uri ( '/manager/', '/manager/users', '/manager' ) {
        local $ENV{REDIRECT_URL} = $uri;
        my @h = ProcessorHeadersUnderTest::_security_headers( html => $html );
        ok( ( grep { /^Content-Security-Policy-Report-Only:/ } @h ),
            "$uri is report-only even so" )
            or diag( 'Enforcing here disables the cache, audit, sessions and '
                . 'plugins controls, and the operator gets no error - the '
                . 'button simply does nothing.' );
        ok( !( grep { /^Content-Security-Policy:/ } @h ),
            "and carries no enforcing header" );
    }
};

subtest 'the hashes are what a browser would compute' => sub {
    # Computed here from first principles rather than by calling the thing under
    # test, because a hash that is wrong in both copies agrees with itself
    # perfectly and blocks the script in every browser while every test passes.
    my @want = map { "'sha256-" . encode_base64( sha256($_), '' ) . "'" }
        ( 'var a = 1;  ', "\n  (function(){ document.title = \"x\"; })();\n" );

    my @got = Lazysite::SecurityHeaders::inline_script_hashes($FIXTURE);
    is_deeply( \@got, \@want, 'both inline bodies, hashed over their exact bytes' )
        or diag( 'A hash computed over trimmed or normalised source matches '
            . 'nothing, and fails silently in the browser on a page that '
            . 'renders blank.' );
    is( scalar @got, 2, 'the repeat collapsed and the <script src> was skipped' );
};

subtest 'HSTS is short, unqualified, and secure-only' => sub {
    # The value is the whole risk. A browser that has seen this refuses plain
    # HTTP to the host for max-age seconds and there is no way to reach a
    # visitor who has already been told, so a default that ships wrong cannot be
    # withdrawn - only waited out.
    cmp_ok( $Lazysite::SecurityHeaders::HSTS_MAX_AGE, '<=', 86_400,
        'max-age is a short starting value, not a ramped one' )
        or diag( 'Raising it is an operator decision against a running fleet. '
            . 'Shipping it raised is a decision made blind on their behalf.' );

    my ($hsts) = grep { /^Strict-Transport-Security:/ }
        Lazysite::SecurityHeaders::security_headers( https => 1 );
    ok( $hsts, 'HSTS is emitted over TLS' );
    unlike( $hsts, qr/includeSubDomains/,
        'without includeSubDomains - it binds hosts this instance may not serve' );
    unlike( $hsts, qr/preload/,
        'and without preload, which is effectively irreversible and is the '
            . "domain owner's decision rather than the engine's" );

    my @plain = Lazysite::SecurityHeaders::security_headers( https => 0 );
    is( scalar( grep { /^Strict-Transport-Security:/ } @plain ),
        0, 'and none at all over plain HTTP' );
};

subtest 'and no response path answers without it' => sub {
    # SM381. The subtest below catches a path that writes its own COPY of the
    # headers. This catches the commoner and quieter case: a path that writes a
    # status line and no headers at all.
    #
    # The comment on _security_headers claimed "every response path here calls
    # this" and had been wrong for longer than the defect it described - 402,
    # 403, three other refusals, five redirects, the 500, the registry outputs
    # and two .well-known endpoints each printed their own. A comment asserting
    # completeness is a claim like any other; this makes it checkable.
    #
    # COMMENTS ARE SKIPPED, because the corrected comment quotes the very string
    # this searches for and an earlier version of this check flagged it. The
    # same self-match that made the subtest below need its $in_def guard.
    my @naked;
    for my $file (@PROCESSOR) {
        open my $fh, '<', "$root/$file" or die "$file: $!";
        my @lines = <$fh>;
        close $fh;

        my $sub;
        for my $i ( 0 .. $#lines ) {
            my $l = $lines[$i];
            $sub = $1 if $l =~ /^\s*sub (\w+)/;
            next if $l =~ /^\s*#/;
            next unless $l =~ /print "Status:/;
            next if ( $sub // '' ) eq 'output_page';    # the choke point itself

            my $window = join '', grep { !/^\s*#/ }
                @lines[ $i .. ( $i + 7 > $#lines ? $#lines : $i + 7 ) ];
            push @naked, "$file: " . ( $sub // '?' ) . " (line @{[ $i + 1 ]})"
                unless $window =~ /_security_headers/;
        }
    }

    is_deeply( \@naked, [],
        'every status line is output_page or is followed by the header set' )
        or diag( join "\n  ",
        '', @naked, '',
        'These answer a request without nosniff, frame options, referrer',
        'policy or HSTS. The refusals are the ones that matter most: they are',
        'what a scanner reaches.' );
};

subtest 'every response path emits the set' => sub {
    # The defect this replaces was three paths writing a shorter list. Anything
    # printing the first header by hand is a path that has started its own.
    my @stray;
    for my $file ( @PROCESSOR, 'lazysite-front.pl' ) {
        open my $fh, '<', "$root/$file" or die $!;
        my ( $n, $in_def ) = ( 0, 0 );
        while ( my $l = <$fh> ) {
            $n++;

            # The definition names all four headers, so without this the check
            # flags its own subject - a mistake worth leaving a note about,
            # since it looked exactly like a real finding.
            $in_def = 1 if $l =~ /^sub _security_headers \{/;
            if ($in_def) { $in_def = 0 if $l =~ /^\}/; next }

            next if $l     =~ /^\s*#/;
            next unless $l =~ /X-Content-Type-Options|X-Frame-Options|Referrer-Policy/;
            next if $l     =~ /_security_headers|security_headers\(/;
            push @stray, "$file:$n";
        }
        close $fh;
    }
    is_deeply( \@stray, [],
        'no response path spells a security header out for itself' )
        or diag( "Hand-written at: @stray\n"
            . 'That is how three of four paths ended up shorter than the '
            . 'fourth, invisibly to anyone probing the homepage.' );
};

# SM1266: THE DEFAULT, PINNED. A page that asks for nothing sends exactly the
# line every response sent before a page could ask - SM1174's camera page and
# SM1266's lifting of the camera-only lock change nothing for it. Written out
# here rather than built from either list, so a feature dropped from both, or a
# reorder in both, still fails.
my $DEFAULT_PP = 'Permissions-Policy: accelerometer=(), browsing-topics=(), camera=(), '
    . 'display-capture=(), geolocation=(), gyroscope=(), magnetometer=(), '
    . 'microphone=(), midi=(), payment=(), usb=(), xr-spatial-tracking=()';

subtest 'SM1266: the default Permissions-Policy is the denied list, every feature =()' => sub {
    for my $https ( 0, 1 ) {
        local $ENV{HTTPS} = $https ? 'on' : '';
        my ($m) = grep {/^Permissions-Policy:/} Lazysite::SecurityHeaders::security_headers( https => $https );
        my ($c) = grep {/^Permissions-Policy:/} ProcessorHeadersUnderTest::_security_headers();
        is( $m, $DEFAULT_PP, "https=$https: the module's default is the pinned line" );
        is( $c, $DEFAULT_PP, "https=$https: and so is the processor's" );
        my ($asked) = grep {/^Permissions-Policy:/} ProcessorHeadersUnderTest::_security_headers( permissions => [] );
        is( $asked, $DEFAULT_PP, '...and an empty ask is the default too' );
    }
    is_deeply( [ ProcessorHeadersUnderTest::_pp_denied() ], \@Lazysite::SecurityHeaders::DENIED_FEATURES,
        'the processor denies the same features, in the same order' );
    is_deeply( [ ProcessorHeadersUnderTest::_pp_page_may_ask() ], \@Lazysite::SecurityHeaders::PAGE_FEATURES,
        'and a page may ask for the same ones in both' );
};

subtest 'SM1266: any feature a page may ask for is the same decision in both, and https-only' => sub {
    my @may = @Lazysite::SecurityHeaders::PAGE_FEATURES;
    ok( ( grep { $_ eq 'geolocation' } @may ) && ( grep { $_ eq 'microphone' } @may ),
        'geolocation and microphone are among them - the lock is gone' );
    ok( !( grep { $_ eq 'payment' } @may ), 'payment is not: `payment:` is the paid-page key (SM980)' );
    is_deeply( \@may, [ grep { $_ ne 'payment' } @Lazysite::SecurityHeaders::DENIED_FEATURES ],
        'and it is the denied list less payment, in its order' );
    for my $https ( 0, 1 ) {
        local $ENV{HTTPS} = $https ? 'on' : '';
        for my $ask ( ( map { [$_] } @Lazysite::SecurityHeaders::DENIED_FEATURES ),
            [qw(geolocation microphone)], [qw(camera nonsense)] )
        {
            my @module = Lazysite::SecurityHeaders::security_headers( https => $https, permissions => $ask );
            my @copy   = ProcessorHeadersUnderTest::_security_headers( permissions => $ask );
            is_deeply( \@copy, \@module, "https=$https asks @$ask: the same lines" );
            my ($pp) = grep {/^Permissions-Policy:/} @copy;
            my %granted = map { $_ => 1 } grep { my $f = $_; $https && grep { $_ eq $f } @may } @$ask;
            ( my $want = $DEFAULT_PP ) =~ s/(?<=[ :])([a-z-]+)=\(\)/$granted{$1} ? "$1=(self)" : "$1=()"/ge;
            is( $pp, $want, '...and only what was asked for and may be is (self)' );
        }
    }
};

subtest 'SM1174: the camera allowance is the same decision in both, and https-only' => sub {
    for my $https ( 0, 1 ) {
        for my $camera ( 0, 1 ) {
            local $ENV{HTTPS} = $https ? 'on' : '';
            my @module = Lazysite::SecurityHeaders::security_headers( https => $https, camera => $camera );
            my @copy   = ProcessorHeadersUnderTest::_security_headers( permissions => $camera ? ['camera'] : [] );
            is_deeply( \@copy, \@module, "https=$https camera=$camera: the same lines" );
            my ($pp) = grep {/^Permissions-Policy:/} @copy;
            my $want = ( $https && $camera ) ? 'camera=(self)' : 'camera=()';
            like( $pp, qr/\Q$want\E,/, "...and the policy carries $want" );
            is( scalar( () = $pp =~ /\(self\)/g ), ( $https && $camera ) ? 1 : 0, '...with no other directive relaxed' );
        }
    }
};

done_testing();
