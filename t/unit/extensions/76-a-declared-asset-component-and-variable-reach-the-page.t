#!/usr/bin/perl
# SM1369 X5, the asset part of H-10 (ruling 55): WHAT AN EXTENSION DECLARES
# REACHES THE PAGE THROUGH THE INDEX, AND NOTHING ELSE DOES.
#
# A fixture extension declares an asset (with an inject_when attribute, an
# alias and an attrs function), a component and a template variable, through a
# real enable (the manager builds the index). Then, through the real processor
# as a child:
#
#   * the asset is served at /assets/<id>-<file> and at its alias, from the
#     payload, as a script;
#   * it is added once to a page whose markup carries the attribute, with the
#     data attributes its function answers (escaped), and not to a page without;
#   * the layout variable renders what the function answers, and the ::: component
#     renders from the payload's templates/components;
#   * disabled, the variable is empty, the component is not one, the asset is
#     not found and nothing is injected (G-1, off means off);
#   * the processor's module-free reader and Lazysite::Extensions::Hooks read
#     the same index to the same answer;
#   * a declaration naming a file that is not in the payload, an alias of the
#     engine's own asset, or a variable the engine gives every layout, is refused.
#
# Sabotage: drop the enabled check from _extension_entries and the disabled
# case still serves the asset - this fails.
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use File::Basename qw(dirname);
use JSON::PP   qw(decode_json);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use lib "$FindBin::Bin/../../../lib";
use TestHelper qw(site_tempdir run_processor load_processor silence_stdout);
use Lazysite::Manager::Extensions qw(action_extension_enable action_extension_disable);
use Lazysite::Extensions::Hooks   qw(read_index validate_hooks);

$ENV{LAZYSITE_LOG_LEVEL} = 'ERROR';

sub spit { my ( $p, $c ) = @_; open my $fh, '>', $p or die "$p: $!"; print {$fh} $c; close $fh; return }

sub write_extension {
    my ( $path, $desc ) = @_;
    my $json = JSON::PP->new->canonical->encode($desc);
    $json =~ s/'/'\\''/g;
    spit( $path, "#!/usr/bin/perl\nprint q'$json' if \@ARGV && \$ARGV[0] eq '--describe';\nexit 0;\n" );
    chmod 0755, $path or die $!;
    return;
}

my $N = 0;

sub fixture {
    my (%o) = @_;
    my $M    = 'ProbeVars' . ++$N;
    my $d    = site_tempdir();
    my $base = dirname($d);
    make_path( "$d/lazysite/layouts/plain", "$base/extensions/probe/lib/$M", "$base/extensions/probe/assets",
        "$base/extensions/probe/templates/components" );
    spit( "$d/lazysite/lazysite.conf", "site_name: T\nlayout: plain\n" );
    spit( "$d/lazysite/layouts/plain/layout.tt",
        '<!DOCTYPE html><html><head><title>[% page_title %]</title></head>'
            . '<body><header>[% probe_greeting %]</header><main>[% content %]</main></body></html>' );
    write_extension( "$base/extensions/probe.pl", {
            id => 'probe', name => 'Probe', contract => 1,
            config_file => 'lazysite/probe.conf', config_schema => [ { key => 'note', label => 'Note', type => 'text' } ],
            owns => { hooks => $o{hooks} // {
                    assets => [ { file => 'probe.js', inject_when => 'data-ls-probe', alias => '/assets/probe-alias.js',
                            attrs => "${M}::attrs" } ],
                    components    => [ { file => 'probe-box.tt' } ],
                    template_vars => [ { name => 'probe_greeting', render => "${M}::greeting" } ],
                } } } );
    spit( "$base/extensions/probe/lib/$M.pm",
        "package $M;\nsub greeting { my (\$ctx) = \@_; return '<b>hello from ' . (ref \$ctx eq 'HASH' && \$ctx->{docroot} ? 'the site' : '?') . '</b>' }\n"
            . "sub attrs { return { 'data-ls-probe-name' => 'A&B <i>', onclick => 'alert(1)', 'data-ls-probe-ref' => {} } }\n1;\n" );
    spit( "$base/extensions/probe/assets/probe.js",         "/* probe.js */ window.probe = 'PROBE-ASSET-BYTES';\n" );
    spit( "$base/extensions/probe/templates/components/probe-box.tt", '<div class="probe-box">[% content %]|[% probe_greeting %]</div>' );
    spit( "$d/page.md",  "---\ntitle: P\n---\n\n<div data-ls-probe=\"x\"></div>\n\n::: probe-box\nInside.\n:::\n" );
    spit( "$d/plain.md", "---\ntitle: Plain\n---\n\nJust words.\n" );
    $Lazysite::Manager::Extensions::DOCROOT = $d;
    return ( $base, $d );
}

sub status_of { my ($r) = @_; my ($s) = $r =~ /Status:\s*(\d+)/; return $s // 200 }

subtest 'enabled: the asset is served, injected once, the variable and the component render' => sub {
    my ( $base, $d ) = fixture();
    my $r = action_extension_enable('extensions/probe.pl');
    ok( $r->{ok}, 'enabled' ) or diag explain $r;
    is_deeply( $r->{index}{indexed}, ['probe'], 'and indexed' ) or diag explain $r->{index};
    my $idx = read_index("$d/lazysite")->{extensions}{probe};
    is( $idx->{payload}, "$base/extensions/probe", 'the index names the payload directory' );

    for my $path ( '/assets/probe-probe.js', '/assets/probe-alias.js' ) {
        my $out = run_processor( $d, $path );
        is( status_of($out), 200, "$path answers 200" );
        like( $out, qr{^Content-Type: text/javascript}mi, '...as a script' );
        like( $out, qr/PROBE-ASSET-BYTES/, '...with the payload file\'s bytes' );
        like( $out, qr/^ETag: W\//m, '...with a validator' );
    }
    is( status_of( run_processor( $d, '/assets/probe-other.js' ) ), 404, 'a file the declaration does not name is not found' );

    my $html = run_processor( $d, '/page' );
    my $n = () = $html =~ m{<script src="/assets/probe-alias\.js\?v=[^"]*" data-ls-probe-name="A&amp;B &lt;i&gt;" defer></script>}g;
    is( $n, 1, 'the script is injected once, by its alias, with the escaped data attribute its function answers' );
    unlike( $html, qr/onclick|probe-ref/, 'an attribute that is not a data attribute, or not a plain value, is dropped' );
    like( $html, qr{<header><b>hello from the site</b></header>}, 'the layout variable renders what the function answers' );
    like( $html, qr{<div class="probe-box"><p>Inside\.</p>\|<b>hello from the site</b></div>},
        'the component renders from the payload, with the variable in its stash' );

    my $plain = run_processor( $d, '/plain' );
    unlike( $plain, qr{/assets/probe}, 'a page without the attribute gets no script' );
    like( $plain, qr{<header><b>hello from the site</b></header>}, 'but its layout variable all the same' );
};

subtest 'disabled: nothing of it reaches the page' => sub {
    my ( $base, $d ) = fixture();
    action_extension_enable('extensions/probe.pl');
    my $r = action_extension_disable('extensions/probe.pl');
    ok( $r->{ok}, 'disabled' );
    ok( !-e "$d/lazysite/extensions.index.json", 'the index is gone with the last hooks' );
    is( status_of( run_processor( $d, '/assets/probe-probe.js' ) ), 404, 'the asset is not found' );
    my $html = run_processor( $d, '/page' );
    like( $html, qr{<header></header>}, 'the variable is empty' );
    unlike( $html, qr{/assets/probe|hello from}, 'no script, and nothing the component renders' );
    like( $html, qr{<div class="probe-box">\s*<p>Inside\.</p>\s*</div>}, 'the fence is a plain div, not the component' );

    # An index left behind (a failed write, a copied site) still serves nothing
    # of an extension the conf does not list: the enabled list is read again.
    action_extension_enable('extensions/probe.pl');
    ok( -e "$d/lazysite/extensions.index.json", 'indexed again' );
    spit( "$d/lazysite/lazysite.conf", "site_name: T\nlayout: plain\n" );
    is( status_of( run_processor( $d, '/assets/probe-probe.js' ) ), 404, 'an index entry of an extension not in the conf serves nothing' );
    unlike( run_processor( $d, '/page' ), qr{/assets/probe|hello from}, '...and renders nothing' );
};

subtest 'the two readers of the index agree' => sub {
    my ( $base, $d ) = fixture();
    action_extension_enable('extensions/probe.pl');
    silence_stdout { load_processor($d) };
    my $hooks = read_index("$d/lazysite")->{extensions};
    my $proc  = main::_extension_index();
    is_deeply( $proc, $hooks, 'the processor\'s module-free reader reads what Hooks reads' );
    ok( scalar( grep { $_->[0] eq 'probe' } @{ main::_extension_entries() } ), 'and lists the enabled extension' );
    spit( "$d/lazysite/lazysite.conf", "site_name: T\nlayout: plain\n" );
    is_deeply( main::_extension_entries(), [], 'the entries follow the conf, not the index alone' );
};

subtest 'a declaration naming what is not there, or what is core\'s, is refused' => sub {
    my ( $base, $d ) = fixture( hooks => { assets => [ { file => 'absent.js' } ] } );
    my $r = action_extension_enable('extensions/probe.pl');
    ok( !$r->{ok}, 'a file not in the payload: not enabled' );
    like( $r->{error} // '', qr/assets\/absent\.js is not a file in the extension's payload/, 'naming it' );

    my $e = [ map { $_->{error} } validate_hooks( 'x', { assets => [ { file => 'x.js', alias => '/assets/lazysite-chrome.js' } ] } ) ];
    like( $e->[0] // '', qr/engine's own assets/, 'an alias of a core asset is refused' );
    $e = [ map { $_->{error} } validate_hooks( 'x', { assets => [ { file => '../x.js' } ] } ) ];
    like( $e->[0] // '', qr/not a path/, 'a path is not a file name' );
    $e = [ map { $_->{error} } validate_hooks( 'x', { assets => [ { file => 'x.js', inject_when => 'onload' } ] } ) ];
    like( $e->[0] // '', qr/data attribute/, 'inject_when is a data attribute' );
    $e = [ map { $_->{error} } validate_hooks( 'x', { template_vars => [ { name => 'content', render => 'A::b' } ] } ) ];
    like( $e->[0] // '', qr/every layout/, 'a core variable\'s name is refused' );
    $e = [ map { $_->{error} } validate_hooks( 'x', { components => [ { file => 'box.html' } ] } ) ];
    like( $e->[0] // '', qr/<name>\.tt/, 'a component is a .tt' );
    is_deeply( [ validate_hooks( 'x', { assets => [ { file => 'x.css' } ], components => [ { file => 'a.tt' } ],
                    template_vars => [ { name => 'a_b', render => 'A::b' } ] } ) ], [], 'a sound declaration passes' );
};

done_testing;
