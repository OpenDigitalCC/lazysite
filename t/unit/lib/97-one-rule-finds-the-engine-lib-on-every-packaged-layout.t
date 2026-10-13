#!/usr/bin/perl
# SM1078: ONE RULE FINDS THE ENGINE'S LIB, on every packaged layout, and where
# a CGI found it before it finds the same directory.
#
# install.pl puts the Lazysite:: tree at {DOCROOT}/../lib and the CGIs at
# {CGIBIN}, wherever --cgibin is. Before SM1078 each CGI looked only relative to
# its own real directory - bin/lib, bin/../lib, bin/../../lib (lazysite-data.pl
# and lazysite-odoo.pl: the first two) - so on install.pl's own usage example,
# /var/www/html with /usr/lib/cgi-bin, nothing was found and every CGI died
# "Can't locate Lazysite/...". The rule now ends with the docroot's ../lib.
#
# The rule is EVALUATED FROM EACH SHIPPED SCRIPT (t/lint/263 holds every copy to
# one text), and the layouts are read from what ships, as t/unit/lib/90 reads
# them for the processor:
#   where lib goes      dist/config/classification.json ({DOCROOT}/../lib)
#   where CGIs go       the same file ({CGIBIN}/NAME)
#   provision / deb     tools/lazysite-hestia-domain.pl and the vhost tools'
#                       default: <dom>/public_html + <dom>/cgi-bin
#   install.pl          its usage example: /var/www/html + /usr/lib/cgi-bin
#   dev server, demo,   the CGIs run from the payload (repo, tarball or
#   deb pool            /usr/share/lazysite) with lib beside them
#   plugin links        install.pl links form-handler/payment-demo into the
#                       cgi-bin from {DOCROOT}/../plugins, or copies them there
#   doc-only            docs/OPERATOR.md: a cgi-bin inside the docroot
use strict;
use warnings;
use Test::More;
use File::Path     qw(make_path);
use File::Basename qw(dirname basename);
use Cwd            qw(abs_path);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(repo_root);

my $root = repo_root();

sub slurp {
    my ($p) = @_;
    open my $fh, '<', $p or die "$p: $!";
    local $/;
    return scalar <$fh>;
}

# --- the shipped facts -------------------------------------------------------

my $cls = slurp("$root/dist/config/classification.json");
like( $cls, qr{"install_to": "\{DOCROOT\}/\.\./lib/\$1"}, 'install.pl puts the modules at {DOCROOT}/../lib' );
like( $cls, qr{"install_to": "\{CGIBIN\}/\$0"}, 'and the CGIs at {CGIBIN}' );
like( slurp("$root/install.pl"), qr{install\.pl --docroot /var/www/html --cgibin /usr/lib/cgi-bin},
    'install.pl\'s own example puts the cgi-bin at /usr/lib/cgi-bin' );
my $hd = slurp("$root/tools/lazysite-hestia-domain.pl");
like( $hd, qr{\$docroot = "\$domdir/public_html"}, 'Hestia provision: the docroot is <dom>/public_html' );
like( $hd, qr{\$cgibin  = "\$domdir/cgi-bin"}, 'and the cgi-bin <dom>/cgi-bin' );
like( slurp("$root/tools/$_"), qr{dirname\(\$docroot\) \. '/cgi-bin'},
    "$_: the cgi-bin defaults to the docroot's sibling" )
    for qw(lazysite-nginx-vhost.pl lazysite-apache-vhost.pl);
like( slurp("$root/tools/lazysite-cli.pl"), qr{\$o->\{docroot\} = "\$dir/public_html";\n\s+\$o->\{cgibin\}  = "\$dir/cgi-bin";},
    'lazysite provision --installdir: the same pair' );
my ($linked) = slurp("$root/install.pl") =~ m{for my \$plugin \(qw\(([^)]+)\)\) \{};
ok( defined $linked, 'install.pl names the plugins it links into the cgi-bin' );
my @linked = split ' ', $linked // '';

# --- the rule, from each script ----------------------------------------------

opendir my $dh, $root or die $!;
my @cgis = sort grep { /\Alazysite-[a-z-]+\.pl\z/ && -f "$root/$_" } readdir $dh;
closedir $dh;

# The three lines of the rule, lifted from the script and run as a sub of $bin.
sub rule_of {
    my ($file) = @_;
    my @l      = split /\n/, slurp($file);
    my ($i)    = grep { $l[$_] =~ /\A\s*for my \$cand \( "\$bin\/lib"/ } 0 .. $#l;
    die "$file: no lib candidate list\n" unless defined $i;
    my ($doc) = grep { /\A\s*my \$doc = \$ENV\{DOCUMENT_ROOT\}/ } @l;
    my $code = "sub { my (\$bin) = \@_; local \@INC = (); "
        . ( $doc // '' ) . "\n$l[$i]\n$l[$i+1]\n}\nreturn \$INC[0]; }";
    my $sub = eval $code or die "$file: $@";    ## no critic (ProhibitStringyEval)
    return $sub;
}
my %rule = map { ( $_ => rule_of("$root/$_") ) } @cgis;
$rule{"plugins/$_.pl"} = rule_of("$root/plugins/$_.pl") for @linked;

# The rule before SM1078, verbatim: relative to the script only.
sub before {
    my ( $script, $bin ) = @_;
    my @c = ( "$bin/lib", "$bin/../lib" );
    push @c, "$bin/../../lib" unless $script =~ /\Alazysite-(?:data|odoo)\.pl\z/;
    for my $c (@c) { return $c if -d "$c/Lazysite" }
    return undef;
}

sub real { my ($p) = @_; return defined $p ? ( abs_path($p) // $p ) : undef }

# --- the layouts -------------------------------------------------------------

my $t = abs_path( TestHelper::site_tempdir( leaf => 'x' ) . '/..' );

sub lib_at { my ($d) = @_; make_path("$d/Lazysite"); return $d }

sub install_layout {
    my ( $docroot, $cgibin, %o ) = @_;
    make_path( $docroot, $cgibin, "$docroot/../plugins" );
    lib_at("$docroot/../lib");
    for my $p (@linked) {
        open my $fh, '>', "$docroot/../plugins/$p.pl" or die $!;
        close $fh;
        if ( $o{copy_plugins} ) { open my $c, '>', "$cgibin/$p.pl" or die $!; close $c }
        else { symlink( abs_path("$docroot/../plugins") . "/$p.pl", "$cgibin/$p.pl" ) or die $! }
    }
    return;
}

# name => [ docroot, directory the CGIs run from, the lib they must use, fixed? ]
my %layout;
{
    install_layout( "$t/web/example.com/public_html", "$t/web/example.com/cgi-bin" );
    $layout{'provision (deb, Hestia, vhost default)'} =
        [ "$t/web/example.com/public_html", "$t/web/example.com/cgi-bin", "$t/web/example.com/lib" ];

    install_layout( "$t/var/www/html", "$t/usr/lib/cgi-bin" );
    $layout{'install.pl --cgibin /usr/lib/cgi-bin'} = [ "$t/var/www/html", "$t/usr/lib/cgi-bin", "$t/var/www/lib" ];

    install_layout( "$t/copied/public_html", "$t/copied/cgi-bin", copy_plugins => 1 );
    $layout{'provision, plugins copied (no symlinks)'} =
        [ "$t/copied/public_html", "$t/copied/cgi-bin", "$t/copied/lib" ];

    install_layout( "$t/away/var/www/html", "$t/away/usr/lib/cgi-bin", copy_plugins => 1 );
    $layout{'install.pl example, plugins copied'} =
        [ "$t/away/var/www/html", "$t/away/usr/lib/cgi-bin", "$t/away/var/www/lib" ];

    # The payload (repo, tarball, /usr/share/lazysite): the dev server, `lazysite
    # demo` and the deb pool run the CGIs from here. The demo's site has a lib of
    # its own too; the payload's, beside the script, must still win.
    make_path("$t/payload");
    lib_at("$t/payload/lib");
    install_layout( "$t/demo/public_html", "$t/demo/cgi-bin" );
    $layout{'payload (dev server, demo, deb pool)'} = [ "$t/demo/public_html", "$t/payload", "$t/payload/lib" ];

    install_layout( "$t/inside/public_html", "$t/inside/public_html/cgi-bin" );
    $layout{'doc-only: cgi-bin inside the docroot'} =
        [ "$t/inside/public_html", "$t/inside/public_html/cgi-bin", "$t/inside/lib" ];
}

my ( $kept, @fixed ) = (0);
for my $name ( sort keys %layout ) {
    my ( $docroot, $run, $want ) = @{ $layout{$name} };
    my %seen;
    for my $script ( sort keys %rule ) {
        my $path = $script =~ m{\Aplugins/} && $run ne "$t/payload" ? "$run/" . basename($script) : "$run/$script";
        if ( !-e $path ) {    # the payload carries its plugins under plugins/
            make_path( dirname($path) );
            open my $fh, '>', $path or die "$path: $!";
            close $fh;
        }
        my $bin  = dirname( abs_path($path) );
        my $case = "$name: $script";
        local $ENV{DOCUMENT_ROOT} = $docroot;
        delete local $ENV{REDIRECT_DOCUMENT_ROOT};
        my $new = $rule{$script}->($bin);
        my $old = before( basename($script), $bin );
        ok( defined $new, "$case: the lib is found" );
        is( real($new), real($want), "$case: it is the layout's lib" );
        if ( defined $old ) {
            is( real($new), real($old), "$case: where it was found before, the same directory" );
            $kept++;
        }
        else {
            push @fixed, $case;
        }
        $seen{ real($new) // 'none' }++;
    }
    is( scalar keys %seen, 1, "$name: every CGI uses the same lib" );
}
cmp_ok( $kept, '>', 0, "$kept layout/CGI cases kept their lib" );

# The cases that found nothing before: every CGI on install.pl's example (bar the
# linked plugins, which resolve through the link to {DOCROOT}/../plugins), and on
# the doc-only inside-the-docroot layout the two scripts with the short list.
my @expect = (
    ( map { "install.pl --cgibin /usr/lib/cgi-bin: $_" } @cgis ),
    ( map { "install.pl example, plugins copied: $_" } @cgis, map { "plugins/$_.pl" } @linked ),
    ( map { "doc-only: cgi-bin inside the docroot: $_" } qw(lazysite-data.pl lazysite-odoo.pl) ),
);
is_deeply( [ sort @fixed ], [ sort @expect ], 'exactly these found no lib before and find it now' )
    or diag explain \@fixed;

# --- the docroot's ../lib is the last resort ---------------------------------

subtest 'with no docroot in the environment the rule is the old rule' => sub {
    delete local $ENV{DOCUMENT_ROOT};
    delete local $ENV{REDIRECT_DOCUMENT_ROOT};
    for my $name ( sort keys %layout ) {
        my ( undef, $run ) = @{ $layout{$name} };
        my $bin = abs_path($run);
        is( real( $rule{'lazysite-mcp.pl'}->($bin) ), real( before( 'lazysite-mcp.pl', $bin ) ), "$name: unchanged" );
    }
};

subtest 'REDIRECT_DOCUMENT_ROOT stands in for DOCUMENT_ROOT' => sub {
    my ( $docroot, $run, $want ) = @{ $layout{'install.pl --cgibin /usr/lib/cgi-bin'} };
    delete local $ENV{DOCUMENT_ROOT};
    local $ENV{REDIRECT_DOCUMENT_ROOT} = $docroot;
    is( real( $rule{'lazysite-auth.pl'}->( abs_path($run) ) ), real($want), 'the docroot\'s ../lib' );
};

subtest 'a lib beside the script wins over the docroot\'s' => sub {
    my ( $docroot, $run ) = @{ $layout{'payload (dev server, demo, deb pool)'} };
    ok( -d "$docroot/../lib/Lazysite", 'the demo site has a lib of its own' );
    local $ENV{DOCUMENT_ROOT} = $docroot;
    is( real( $rule{'lazysite-processor.pl'}->( abs_path($run) ) ), real("$run/lib"), 'the payload\'s is used' );
};

subtest 'a docroot with no lib beside it adds nothing' => sub {
    my $bin = "$t/bare/cgi-bin";
    make_path( $bin, "$t/bare/public_html" );
    local $ENV{DOCUMENT_ROOT} = "$t/bare/public_html";
    is( $rule{'lazysite-dav.pl'}->($bin), undef, 'no candidate: @INC is left alone' );
};

done_testing();
