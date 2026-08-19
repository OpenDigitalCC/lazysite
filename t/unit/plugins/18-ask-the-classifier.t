#!/usr/bin/perl
# SM392: the classifier is askable without generating traffic.
#
# Testing the ai class from outside needs a clean visitor token, and an agent
# that has done ANY probing cannot get one until its token rolls at UTC
# midnight - the partner agent measured that as one clean run per day, and an
# eleven-agent classification test was invalidated by it. `--classify` answers
# from the same classify(), the same compiled rules and the same operator
# overrides, writing no log line.
#
# Driven through the REAL script as a subprocess - the same surface an agent
# or operator would call - not by importing the sub, so the arg plumbing, the
# config load and the rule compilation are all inside the test boundary.
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use File::Temp qw(tempdir);
use JSON::PP   qw(decode_json);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(repo_root);

my $plugin = repo_root() . '/plugins/stats.pl';
plan skip_all => "no $plugin" unless -f $plugin;

my $d = tempdir( CLEANUP => 1 );
make_path("$d/lazysite");

sub ask {
    my (@argv) = @_;
    my $args   = join ' ', map { quotemeta } ( '--classify', @argv, '--docroot', $d );
    my $out    = qx($^X \Q$plugin\E $args 2>/dev/null);
    my $r      = eval { decode_json($out) };
    return $r // { ok => 0, error => "unparseable: $out" };
}

my $BROWSER = 'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 Chrome/126 Safari/537.36';

subtest 'each class is reachable by construction' => sub {
    is( ask( '--path', '/wp-login.php', '--ua', $BROWSER )->{class},
        'noise', 'a probe path is noise whatever the UA' );
    is( ask( '--path', '/about', '--ua', 'lazysite-agent/claude-code' )->{class},
        'bot', 'the self-identifying tooling UA is bot before anything else' );
    is( ask( '--path', '/about', '--ua', 'GPTBot/1.0' )->{class},
        'ai', 'a known AI UA is ai' );
    is( ask( '--path', '/about', '--ua', $BROWSER )->{class},
        'human', 'a browser on a page is human' );
    is( ask( '--path', '/manager/', '--ua', $BROWSER )->{class},
        'logged_in', 'a browser on the manager surface is operator activity' );
};

subtest 'the status-gated rule needs the status' => sub {
    # SM192: the SPA/build-manifest probe is noise ONLY on a 404 - the same
    # path served 200 is a real asset. A classifier surface that ignored
    # --status would get one of these wrong.
    my $with = ask( '--path', '/asset-manifest.json', '--ua', $BROWSER,
        '--status', '404' );
    is( $with->{class}, 'noise', 'manifest probe + 404 is noise' );
    my $without = ask( '--path', '/asset-manifest.json', '--ua', $BROWSER );
    isnt( $without->{class}, 'noise',
        'the same path with no status is NOT noise - the rule is status-gated' );
};

subtest 'operator overrides from stats.conf are honoured' => sub {
    open my $fh, '>', "$d/lazysite/stats.conf" or die $!;
    print {$fh} "ai_user_agents: acme-crawler\nnoise_paths: /internal-probe\n";
    close $fh;
    is( ask( '--path', '/about', '--ua', 'acme-crawler/2.0' )->{class},
        'ai', 'an operator-listed UA classifies ai' );
    is( ask( '--path', '/internal-probe/x', '--ua', $BROWSER )->{class},
        'noise', 'an operator-listed path prefix classifies noise' );
    unlink "$d/lazysite/stats.conf";
};

subtest 'the surface is honest about what it cannot answer' => sub {
    my $r = ask( '--path', '/about', '--ua', $BROWSER );
    like( $r->{note}, qr/scanner is a visitor-level promotion/,
        'the note says scanner cannot be answered for one line - a verdict it '
            . 'never computed must not be implied (the SM377 class)' );
    my $bad = ask( '--ua', $BROWSER );
    ok( !$bad->{ok}, 'no path is a usage error, not a guess' );
    like( $bad->{error}, qr/--classify --path/, 'and the usage names the fix' );
};

subtest 'asking writes nothing' => sub {
    # The point of the surface is NO traffic and NO state: a diagnostic that
    # dirtied the stats would poison the thing it exists to test.
    #
    # A FRESH docroot, not the shared one - the first version snapshotted the
    # shared fixture after four subtests had already asked, so state created by
    # THOSE asks sat inside the before picture and a sabotage that wrote on
    # every call passed. And the listing is recursive: a file inside a new
    # subdirectory must count.
    my $fresh = tempdir( CLEANUP => 1 );
    make_path("$fresh/lazysite");
    my $deep = sub {
        my @found;
        my @q = ("$fresh/lazysite");
        while ( my $e = shift @q ) {
            for my $c ( sort glob("$e/*") ) {
                push @found, $c;
                push @q,     $c if -d $c;
            }
        }
        return \@found;
    };
    my $before = $deep->();
    for my $probe (
        [ '--path', '/wp-login.php', '--ua', $BROWSER ],
        [ '--path', '/about',        '--ua', 'GPTBot/1.0' ],
        [ '--path', '/about',        '--ua', $BROWSER, '--status', '404' ],
    ) {
        my $args = join ' ', map { quotemeta } ( '--classify', @$probe, '--docroot', $fresh );
        my $out = qx($^X \Q$plugin\E $args 2>/dev/null);
        ok( ( eval { decode_json($out) } // {} )->{ok}, 'the ask itself worked' );
    }
    is_deeply( $deep->(), $before,
        'NOTHING appeared under lazysite/, at any depth - the diagnostic must '
            . 'not poison the thing it exists to test' );
};

done_testing();
