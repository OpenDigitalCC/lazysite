#!/usr/bin/perl
# SM1369 X3 (ruling 55, H-2): A PAGE DATA SOURCE IS DECLARED BY THE EXTENSION.
#
# An extension's `owns.hooks.page_sources` gives a page variable a prefix
# (`x: probe:hello`) that core resolves by calling the extension's own
# `resolve(spec, ctx)` from its payload lib, through the hook index. Core keeps
# the rules a shared, cached render needs, and this drives each through the
# real processor run as the CGI it is, against a fixture extension enabled and
# indexed by the real build:
#
#   * A RENDER IS SHARED: a source that did not declare `per_viewer` is handed
#     no credential - the cookie the request sent never reaches it (G-8);
#   * PER VIEWER: a source that did is handed the request's cookie and
#     identity, and its page is never read from or written to the page cache,
#     is no-store on output, and the next viewer is never served the first
#     one's; a per-viewer source anywhere the mark did not reach is REFUSED;
#   * INERT: what a source answers is HTML-escaped and made unable to spell a
#     link before a template sees it, whatever the source did;
#   * FAILS CLOSED: a source that dies, or answers nothing, is an empty value
#     and ONE WARN line in one shape - the page renders;
#   * `live` withdraws the cache's mtime proof; a plain source is cached;
#   * `check(spec, docroot)` adds issues at the page's save (Lazysite::Validate);
#   * the declaration's vocabulary is refused by name before it is indexed, and
#     two extensions cannot declare one prefix: the later is left out, named.
#
# Sabotage: pass the cookie to every source in sources.pm's resolve_source and
# "no credential reaches a shared render" fails; drop `per_viewer` from the
# peek (auth.pm) and the per-viewer page is written to the cache.
use strict;
use warnings;
use Test::More;
use File::Path     qw(make_path);
use File::Basename qw(dirname);
use JSON::PP       ();
use FindBin;
use lib "$FindBin::Bin/../../lib";
use lib "$FindBin::Bin/../../../lib";
use TestHelper qw(site_tempdir setup_test_site processor_path load_processor);
use File::Find ();
use Lazysite::Manager::Extensions qw(action_extension_enable);
use Lazysite::Extensions::Hooks   qw(validate_hooks index_path);
use Lazysite::Validate            ();

$ENV{LAZYSITE_LOG_LEVEL} = 'ERROR';

sub spit { my ( $p, $c ) = @_; open my $fh, '>', $p or die "$p: $!"; print {$fh} $c; close $fh; return }
sub slurp { open my $fh, '<', $_[0] or return ''; local $/; my $t = <$fh>; close $fh; return $t }

sub write_extension {
    my ( $path, $desc ) = @_;
    my $json = JSON::PP->new->canonical->encode($desc);
    $json =~ s/'/'\\''/g;
    spit( $path, "#!/usr/bin/perl\nprint q'$json' if \@ARGV && \$ARGV[0] eq '--describe';\nexit 0;\n" );
    chmod 0755, $path or die $!;
    return;
}

sub errors { return [ map { $_->{error} } @_ ] }

sub source {
    my ( $prefix, $fn, %over ) = @_;
    return { prefix => $prefix, resolve => "Probe::Sources::$fn", read_only => 1, %over };
}

my $N = 0;

# A site with the probe extension beside it: four sources, each answering
# what it was handed.
sub fixture {
    my (%o)  = @_;
    my $M    = 'Probe' . ++$N;
    my $d    = site_tempdir();
    my $base = dirname($d);
    setup_test_site($d);
    make_path("$base/extensions/probe/lib/${M}");
    my @src = (
        source( 'probe',      'plain', check      => 'Probe::Sources::check' ),
        source( 'probe-me',   'me',    per_viewer => 1 ),
        source( 'probe-live', 'live',  live       => 1 ),
        source( 'probe-boom', 'boom' ),
        source( 'probe-none', 'none' ),
    );
    for my $s (@src) {
        for my $k ( grep { exists $s->{$_} } qw(resolve check) ) { $s->{$k} =~ s/\AProbe::/${M}::/ }
    }
    write_extension( "$base/extensions/probe.pl", {
            id => 'probe', name => 'Probe', contract => 1,
            config_file => 'lazysite/probe.conf', config_schema => [ { key => 'note', label => 'Note', type => 'text' } ],
            owns => { hooks => { page_sources => \@src } } } );
    spit( "$base/extensions/probe/lib/${M}/Sources.pm", <<"PM" );
package ${M}::Sources;
use strict; use warnings;
sub plain { my (\$spec, \$ctx) = \@_; return ( "<b>\$spec</b> via " . (exists \$ctx->{cookie} ? "cookie=\$ctx->{cookie}" : 'no-credential') . " mode=\$ctx->{mode} key=\$ctx->{key}" ) }
sub me    { my (\$spec, \$ctx) = \@_; return ( { who => \$ctx->{cookie}, user => \$ctx->{identity}{user} // '' } ) }
sub live  { my (\$spec) = \@_; return ( "live:\$spec:" . time ) }
sub boom  { die "the probe fell over\\n" }
sub none  { my (\$spec) = \@_; return ( undef, "nothing called '\$spec'", kind => 'absent' ) }
sub check { my (\$spec, \$docroot) = \@_; return \$spec eq 'bad' ? [ { kind => 'probe-bad', message => "'\$spec' is not a thing (\$docroot)" } ] : [] }
1;
PM
    $Lazysite::Manager::Extensions::DOCROOT = $d;
    my $r = action_extension_enable('extensions/probe.pl');
    die 'the fixture did not enable: ' . ( $r->{error} // '?' ) unless $r->{ok} || $o{may_fail};
    return ( $base, $d );
}

# The processor as the CGI it is, with the log captured.
sub render {
    my ( $docroot, $uri, %as ) = @_;
    local %ENV = %ENV;
    delete $ENV{$_} for grep { /\AHTTP_X_REMOTE_|\AHTTP_COOKIE\z/ } keys %ENV;
    $ENV{DOCUMENT_ROOT}      = $docroot;
    $ENV{REDIRECT_URL}       = $uri;
    $ENV{REQUEST_METHOD}     = 'GET';
    $ENV{QUERY_STRING}       = '';
    $ENV{LAZYSITE_LOG_LEVEL} = 'INFO';
    $ENV{HTTP_COOKIE}        = $as{cookie} if defined $as{cookie};
    my $logfile = "$docroot/../render.log";
    unlink $logfile;
    my $proc = processor_path();
    my $out  = qx($^X \Q$proc\E 2>\Q$logfile\E);
    return ( $out, slurp($logfile) );
}

subtest 'the vocabulary is checked before it is indexed' => sub {
    is_deeply( errors( validate_hooks( 'x', { page_sources => [ source( 'rest', 'get' ) ] } ) ), [], 'a sound source passes' );
    my %bad = (
        'the engine\'s own prefix'      => [ source( 'db',    'get' ) ],
        'a prefix with a colon'         => [ source( 'rest:', 'get' ) ],
        'a prefix in capitals'          => [ source( 'Rest',  'get' ) ],
        'no read_only'                  => [ { prefix => 'rest', resolve => 'P::get' } ],
        'read_only 0'                   => [ source( 'rest', 'get', read_only => 0 ) ],
        'per_viewer that is not 0 or 1' => [ source( 'rest', 'get', per_viewer => 'yes' ) ],
        'a prefix declared twice' => [ source( 'rest', 'get' ), source( 'rest', 'put' ) ],
        'no resolve'              => [ { prefix => 'rest', read_only => 1 } ],
        'an unknown key'          => [ source( 'rest', 'get', writes => 1 ) ],
    );
    for my $what ( sort keys %bad ) {
        ok( scalar @{ errors( validate_hooks( 'x', { page_sources => $bad{$what} } ) ) }, "refused: $what" );
    }
    like( errors( validate_hooks( 'x', { page_sources => [ source( 'db', 'get' ) ] } ) )->[0],
        qr/prefix 'db' is the engine's own/, 'the engine\'s prefix refusal names it' );
};

subtest 'a shared render: the source is handed no credential, and its value is made inert' => sub {
    my ( $base, $d ) = fixture();
    spit( "$d/plain.md", "---\ntitle: P\nttl: 300\ntt_page_var:\n  x: probe:hello\n---\nVALUE=[% x %]\n" );
    my ( $out, $log ) = render( $d, '/plain', cookie => 'session=secret' );
    like( $out, qr/VALUE=&lt;b&gt;hello&lt;\/b&gt; via no-credential mode=render key=x/, 'resolved, escaped, with no cookie handed over' );
    unlike( $out, qr/secret/, 'the cookie reached nothing a visitor sees' );
    unlike( $log, qr/WARN/,   'and nothing was warned' );
    ok( -f "$d/plain.html", 'a plain source\'s page is cached' );
    like( $out, qr/VALUE=/, 'rendered' );

    spit( "$d/live.md", "---\ntitle: L\nttl: 300\ntt_page_var:\n  x: probe-live:now\n---\nVALUE=[% x %]\n" );
    render( $d, '/live' );
    is( deps_record( $d, 'plain' ), undef, 'a plain source leaves no dependency record (nothing on disk to watch)' );
    like( deps_record( $d, 'live' ) // '', qr/\A!/, 'a live source withdraws the cache\'s mtime proof (the record\'s live mark)' );
};

# The dependency record the render wrote for a page (sources.pm write_deps), found
# wherever the cache keeps it: its name ends in the page's base and `.deps`.
sub deps_record {
    my ( $d, $page ) = @_;
    my $found;
    File::Find::find( { no_chdir => 1, wanted => sub { $found = $File::Find::name if -f && /\Q$page\E\.deps\z/ } }, "$d/lazysite" );
    return defined $found ? slurp($found) : undef;
}

subtest 'per viewer: handed the cookie, never cached for another viewer' => sub {
    my ( $base, $d ) = fixture();
    spit( "$d/me.md", "---\ntitle: Me\nttl: 300\ntt_page_var:\n  me: probe-me:\n---\nWHO=[% me.who %]|USER=[% me.user %]\n" );
    my ( $a, $loga ) = render( $d, '/me', cookie => 'who=alice' );
    like( $a, qr/WHO=who=alice\|/, 'the first viewer sees their own' );
    ok( !-f "$d/me.html", 'the page is not written to the page cache' );
    like( $a, qr/^Cache-Control:[^\n]*no-store/mi, 'and is no-store on output' );
    my ($b) = render( $d, '/me', cookie => 'who=bob' );
    like( $b, qr/WHO=who=bob\|/, 'the next viewer sees their own' );
    unlike( $b, qr/alice/, 'and never the first one\'s' );
    my ($c) = render( $d, '/me' );
    like( $c, qr/WHO=\|/, 'no cookie: nothing' );

    # A per-viewer source where the mark did not reach: refused, not rendered.
    local $ENV{LAZYSITE_LOG_LEVEL} = 'INFO';
    load_processor($d);
    no warnings 'once';
    local %main::RENDER_QUERY = ();
    local $ENV{HTTP_COOKIE} = 'who=alice';
    my ( %v, $log );
    {
        open my $fh, '>', \$log or die $!;
        local *STDERR = $fh;
        %v = main::resolve_tt_vars( { me => 'probe-me:' } );
    }
    is( $v{me}, '', 'outside the page\'s own front matter it renders empty' );
    like( $log, qr/probe-me: binding refused - it is not in a page's own tt_page_var, so the render could be cached and served to another viewer/,
        'and the log says why' );
};

subtest 'a source that dies, or answers nothing, is empty and one WARN line' => sub {
    my ( $base, $d ) = fixture();
    spit( "$d/boom.md", "---\ntitle: B\ntt_page_var:\n  x: probe-boom:any\n---\nSTART[% x %]END\n" );
    my ( $out, $log ) = render( $d, '/boom' );
    like( $out, qr/STARTEND/, 'the page renders with the value empty' );
    my @warn = grep { /WARN.*\[\/boom\]/ } split /\n/, $log;
    is( scalar @warn, 1, 'one WARN line for the page' ) or diag $log;
    like( $warn[0], qr/probe-boom: page variable did not resolve .*why=.*died: the probe fell over/,
        'in the one shape, with the reason' );
    my ($died) = grep { /\[extension-hook\] a hook died/ } split /\n/, $log;
    ok( $died && $died =~ /extension=probe/ && $died =~ /why=the probe fell over/,
        'and the loader records the extension\'s fault where it happened' ) or diag $log;

    spit( "$d/none.md", "---\ntitle: N\ntt_page_var:\n  x: probe-none:thing\n---\nSTART[% x %]END\n" );
    ( $out, $log ) = render( $d, '/none' );
    like( $out, qr/STARTEND/, 'a source answering nothing: empty' );
    @warn = grep { /WARN/ } split /\n/, $log;
    is( scalar @warn, 1, 'one WARN line' ) or diag $log;
    like( $warn[0], qr/probe-none: page variable read nothing .*why=nothing called 'thing'/, 'with the source\'s reason' );
    like( $warn[0], qr/kind=absent/, 'and its detail' );

    spit( "$d/literal.md", "---\ntitle: L\ntt_page_var:\n  x: https://example.org/\n  y: nobody:here\n---\nX=[% x %] Y=[% y %]\n" );
    ( $out, $log ) = render( $d, '/literal' );
    like( $out, qr{X=https://example.org/ Y=nobody:here}, 'an address and an undeclared prefix stay literals' );
    unlike( $log, qr/WARN/, 'with nothing warned' );
};

subtest 'check: a source adds issues at the page\'s save' => sub {
    my ( $base, $d ) = fixture();
    my $page = sub { "---\ntitle: T\ntt_page_var:\n  x: probe:$_[0]\n---\nbody\n" };
    my $r = Lazysite::Validate::validate_content( content => $page->('bad'), docroot => $d );
    my ($i) = grep { $_->{kind} eq 'probe-bad' } @{ $r->{issues} };
    ok( $i, 'the source\'s check adds its issue, with its own kind' ) or diag explain $r;
    like( $i->{message} // '', qr/'bad' is not a thing \(\Q$d\E\)/, 'with its message, and it was handed the docroot' );
    $r = Lazysite::Validate::validate_content( content => $page->('fine'), docroot => $d );
    ok( !( grep { $_->{kind} eq 'probe-bad' } @{ $r->{issues} } ), 'and nothing for a spec it accepts' );
};

subtest 'two extensions cannot declare one prefix' => sub {
    my ( $base, $d ) = fixture();
    make_path("$base/extensions/rival/lib/Rival");
    spit( "$base/extensions/rival/lib/Rival/S.pm", "package Rival::S;\nsub get { return ('rival') }\n1;\n" );
    write_extension( "$base/extensions/rival.pl", { id => 'rival', name => 'Rival', contract => 1,
            owns => { hooks => { page_sources => [ { prefix => 'probe', resolve => 'Rival::S::get', read_only => 1 } ] } } } );
    my $r = action_extension_enable('extensions/rival.pl');
    ok( $r->{ok}, 'the rival enables' ) or diag explain $r;
    is_deeply( $r->{index}{indexed}, ['probe'], 'but only the first by id is indexed' );
    like( $r->{index}{refused}[0]{problems}[0], qr/prefix 'probe' is already declared by the extension 'probe'/, 'and the index says why' );
};

subtest 'the processor spells the index file as the loader does' => sub {
    my $src = slurp("$FindBin::Bin/../../../lazysite-processor/sources.pm");
    my ($leaf) = index_path('x') =~ m{/([^/]+)\z};
    like( $src, qr/\Q$leaf\E/, "sources.pm names $leaf, the file Hooks::index_path names" );
};

done_testing();
