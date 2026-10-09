#!/usr/bin/perl
# SM976 Q15e (ruled 2026-10-09, "Refuse new binding"): a domain-confined caller
# writes no page that newly binds a form it does not reach. A form is reached
# through the pages that bind it (F2), so a page naming a form made it its site's:
# a cookie manager scoped to one domain saved a page naming the primary's form
# and then read its submissions (tmp/q15d-hijack-probe.out).
#
#   page_form_names         every form a page's text names - as the processor
#                           renders it, and as form_bindings reads it
#   form_bind_refusal       the rule, for a page about to be written
#   form_bind_tree_refusal  the rule, for pages carried somewhere (move, copy)
#   Manager::Files guards   the choke point asks it, with MCP's grant scopes
#
# The instance is 209's: alpha.test at sites/alpha, beta.test at sites/beta, the
# primary. Forms: fa on a page in sites/alpha, fb in sites/beta, fp on a primary
# page, fab on a page in each of alpha and beta; and fp is also bound on
# sites/alpha/shared.md, a page the operator made. On no page: fr registered
# (lazysite/forms/fr.conf), fs with a submissions store only, fm registered as
# Fm.conf, and fnew, which exists nowhere.
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(repo_root site_tempdir);
use lib repo_root() . '/lib';
use Lazysite::Manager::Common qw(page_form_names form_bind_refusal form_bind_tree_refusal);
use Lazysite::Manager::Domains ();
use Lazysite::Manager::Files   ();
use Lazysite::Auth::Acl        ();

my $root = repo_root();
my $d    = site_tempdir();
make_path( "$d/lazysite/auth", "$d/lazysite/manager/locks", "$d/sites/alpha", "$d/sites/beta" );
{
    open my $cf, q(>), "$d/lazysite/lazysite.conf" or die $!;
    print {$cf} "site_name: T\nalias_hosts: alpha.test, beta.test\n"
        . "alias.alpha.test.content_root: sites/alpha\nalias.beta.test.content_root: sites/beta\n";
    close $cf;
}
$Lazysite::Manager::Common::DOCROOT  = $d;
$Lazysite::Manager::Domains::DOCROOT = $d;

sub spit { my ( $p, $t ) = @_; ( my $dir = $p ) =~ s{/[^/]+\z}{}; make_path($dir); open my $fh, '>', $p or die "$p: $!"; print {$fh} $t; close $fh; return }
sub page { my ($f) = @_; return "---\ntitle: P\nform: $f\n---\n\n:::form\nn | N\n:::\n" }
my %PAGE = ( fa => ['sites/alpha/c.md'], fb => ['sites/beta/c.md'], fp => [ 'c.md', 'sites/alpha/shared.md' ],
    fab => [ 'sites/alpha/d.md', 'sites/beta/d.md' ] );
for my $f ( sort keys %PAGE ) { spit( "$d/$_", page($f) ) for @{ $PAGE{$f} } }

my %WHO = (
    'a grant scoped to alpha'          => [ scopes => ['sites/alpha'] ],
    'a grant naming no scope'          => [ scopes => [] ],
    'a grant scoped to alpha and beta' => [ scopes => [ 'sites/alpha', 'sites/beta' ] ],
);

subtest 'page_form_names reads the form as the processor renders it' => sub {
    # The processor's own parts, package main as they are in the processor.
    require "$root/lazysite-processor/oembed.pm";
    require "$root/lazysite-processor/front-matter.pm";
    # front matter => what the processor binds (its parse is the oracle)
    my @cases = (
        "---\nform: leads\n---\n",
        "---\nform: \"leads\"\n---\n",
        "---\nform: 'Leads'\n---\n",
        "---\nform:\n  leads\n---\n",                # the value on the next line
        "---\nform: decoy\nform: leads\n---\n",      # the last key wins
        "---\nform: le.ads\n---\n",                  # the sanitiser drops the dot
        "---\nform: [% x %]leads\n---\n",            # TT markers stripped, then sanitised
        "---\ntitle: T\r\nform: leads\r\n---\r\n",   # CRLF
        "---   \nform: leads  \n---  \n",            # trailing blanks on the fences
    );
    for my $c (@cases) {
        my ($meta) = main::parse_yaml_front_matter($c);
        my $want = lc( $meta->{form} // '' );
        ok( length $want, 'the processor binds a form for: ' . ( $c =~ s/\n/\\n/gr ) );
        ok( ( grep { $_ eq $want } page_form_names($c) ), "...and page_form_names names it ($want)" );
    }
    is_deeply( [ page_form_names("---\nform: leads\nform: other\n---\n") ], [qw(leads other)],
        'both readings are named: the binding (first line) and the render (last)' );
    is_deeply( [ page_form_names("---\ntitle: T\n---\nform: leads\n") ], [], 'a body line binds nothing' );
    is_deeply( [ page_form_names("# no front matter\n") ], [], 'nor does a page without front matter' );
    is_deeply( [ page_form_names(undef) ],                 [], 'nor no text' );
};

subtest 'form_bind_refusal: a new page naming each form' => sub {
    spit( "$d/lazysite/forms/fr.conf",              "targets:\n" );
    spit( "$d/lazysite/forms/Fm.conf",              "targets:\n" );
    spit( "$d/lazysite/forms/submissions/fs.jsonl", "{}\n" );
    #                                         fa fb fp fab fr fs fm fnew
    my %want = (
        'a grant scoped to alpha'          => 'YNNNNNNY',
        'a grant naming no scope'          => 'YYYYYYYY',
        'a grant scoped to alpha and beta' => 'YYNYNNNY',
    );
    my @f = qw(fa fb fp fab fr fs fm fnew);
    for my $who ( sort keys %want ) {
        my @w = split //, $want{$who};
        for my $i ( 0 .. $#f ) {
            my $no = form_bind_refusal( 'sites/alpha/new.md', page( $f[$i] ), @{ $WHO{$who} } );
            is( $no ? 'N' : 'Y', $w[$i], "$who: a new page binding $f[$i]" );
        }
    }
};

subtest 'form_bind_refusal: what is unchanged, and the readings it must not miss' => sub {
    my $alpha = $WHO{'a grant scoped to alpha'};
    ok( !form_bind_refusal( 'sites/alpha/shared.md', page('fp') . "edited\n", @$alpha ),
        'editing a page that already binds the form (fp, which alpha does not reach)' );
    ok( !form_bind_refusal( '/sites/alpha/shared.md', "---\ntitle: P\n---\nno form\n", @$alpha ),
        'removing a binding' );
    ok( form_bind_refusal( 'sites/alpha/shared.md', page('fb'), @$alpha ), 'rebinding that page to another form it does not reach' );
    ok( !form_bind_refusal( 'sites/alpha/c.md', page('fa'), @$alpha ), 'editing its own form\'s page' );
    ok( !form_bind_refusal( 'sites/alpha/new.txt', page('fp'), @$alpha ), 'a file the processor renders no form on (.txt)' );
    ok( form_bind_refusal( 'sites/alpha/new.md', "---\nform:\n  fp\n---\n", @$alpha ), 'the value on the next line' );
    ok( form_bind_refusal( 'sites/alpha/new.md', "---\nform: fa\nform: fp\n---\n", @$alpha ),
        'a second form: line, which the processor renders' );
    ok( form_bind_refusal( 'sites/alpha/new.md', "---\nform: fp\nform: fa\n---\n", @$alpha ),
        'a first form: line, which form_bindings reads' );
    ok( form_bind_refusal( 'sites/alpha/new.md', "---\nform: f.p\n---\n", @$alpha ), 'a name the sanitiser completes' );

    my ( $err, $detail ) = form_bind_refusal( 'sites/alpha/new.md', page('fp'), @$alpha );
    like( $err, qr/'sites\/alpha\/new\.md' would bind the form 'fp'.*which you do not reach/s, 'the refusal names the page and the form' );
    like( $err, qr/Editing a page that already binds a form, and removing a binding, are unchanged/, '...and what still works' );
    like( $detail, qr/\Aform-bind-refused: /, '...with the audit detail every content rule leaves' );
    is( Lazysite::Manager::Common::refusal_status('form-bind-refused'), '403 Forbidden', 'answered 403' );

    local $Lazysite::Manager::Common::token_auth       = 0;
    local $Lazysite::Manager::Common::REQUEST_CONFINED = 0;
    local @Lazysite::Manager::Common::REQUEST_SCOPES   = ();
    ok( !form_bind_refusal( 'sites/alpha/new.md', page('fp') ), 'the unconfined operator is not asked' );
    local $Lazysite::Manager::Common::REQUEST_CONFINED = 1;
    local @Lazysite::Manager::Common::REQUEST_SCOPES   = ('sites/alpha');
    ok( form_bind_refusal( 'sites/alpha/new.md', page('fp') ), 'a scoped cookie manager is' );
};

subtest 'form_bind_tree_refusal: a page carried somewhere binds there' => sub {
    my $alpha = $WHO{'a grant scoped to alpha'};
    ok( form_bind_tree_refusal( "$d/sites/alpha/shared.md", 'sites/alpha/moved.md', @$alpha ),
        'a page binding fp, moved or copied to a new path' );
    ok( !form_bind_tree_refusal( "$d/sites/alpha/c.md", 'sites/alpha/c2.md', @$alpha ), 'its own form\'s page' );
    ok( !form_bind_tree_refusal( "$d/sites/alpha/shared.md", 'sites/alpha/shared.txt', @$alpha ),
        'to a name the processor renders no form on' );
    spit( "$d/sites/alpha/plain.txt", page('fp') );
    ok( form_bind_tree_refusal( "$d/sites/alpha/plain.txt", 'sites/alpha/plain.md', @$alpha ),
        'a text file renamed to a page' );
    spit( "$d/sites/alpha/sec/one.md",     page('fa') );
    spit( "$d/sites/alpha/sec/sub/two.md", page('fp') );
    my ($err) = form_bind_tree_refusal( "$d/sites/alpha/sec", 'sites/alpha/sec2', @$alpha );
    like( $err // '', qr/'sites\/alpha\/sec2\/sub\/two\.md' would bind the form 'fp'/, 'a folder: each page at its new path' );
    ok( !form_bind_tree_refusal( "$d/sites/alpha/sec", 'sites/alpha/sec2', scopes => [] ), 'an unbound grant reaches every form' );
    spit( "$d/sites/alpha/locked/x.md", page('fa') );
    chmod 0, "$d/sites/alpha/locked/x.md";
SKIP: {
        skip 'running as a user that reads an unreadable file', 1 if -r "$d/sites/alpha/locked/x.md";
        ok( form_bind_tree_refusal( "$d/sites/alpha/locked", 'sites/alpha/locked2', @$alpha ),
            'a page that cannot be read cannot be judged, so it is refused' );
    }
    chmod 0644, "$d/sites/alpha/locked/x.md";
};

subtest 'the choke point asks it, with the grant\'s scopes' => sub {
    $Lazysite::Manager::Files::DOCROOT   = $d;
    $Lazysite::Manager::Files::LOCK_DIR  = "$d/lazysite/manager/locks";
    $Lazysite::Manager::Files::auth_user = 'alice';
    $Lazysite::Auth::Acl::DOCROOT        = $d;
    $Lazysite::Auth::Acl::auth_user      = 'alice';
    $Lazysite::Auth::Acl::token_auth     = 0;
    local $Lazysite::Manager::Files::CALLER_SCOPES = ['sites/alpha'];
    my $r = Lazysite::Manager::Files::action_save( 'sites/alpha/hook.md', 'alice', page('fp'), undef );
    ok( !$r->{ok}, 'action_save: a new page binding fp' );
    is( $r->{kind}, 'form-bind-refused', '...as form-bind-refused' );
    ok( !-e "$d/sites/alpha/hook.md", '...and nothing was written' );
    ok( Lazysite::Manager::Files::action_save( 'sites/alpha/shared.md', 'alice', page('fp') . "x\n", undef )->{ok},
        'action_save: editing the page that already binds it' );
    ok( !Lazysite::Manager::Files::action_save_binary( 'sites/alpha/up.md', 'alice', page('fp') )->{ok},
        'action_save_binary' );
    ok( !Lazysite::Manager::Files::action_copy( 'sites/alpha/shared.md', 'sites/alpha/copy.md', 'alice' )->{ok},
        'action_copy' );
    ok( !Lazysite::Manager::Files::action_move( 'sites/alpha/shared.md', 'sites/alpha/moved.md', 'alice' )->{ok},
        'action_move' );
    ok( -e "$d/sites/alpha/shared.md", '...which left the page where it was' );
    ok( Lazysite::Manager::Files::action_move( 'sites/alpha/c.md', 'sites/alpha/c-renamed.md', 'alice' )->{ok},
        'action_move of its own form\'s page' );

    require Lazysite::Fetch;
    spit( "$d/sites/alpha/remote.url", "https://example.com/page\n" );
    {
        no warnings qw(redefine once);
        local *Lazysite::Fetch::fetch_url = sub { page('fp') };
        my $m = Lazysite::Manager::Files::action_migrate_to_local( 'sites/alpha/remote.url', 'alice' );
        ok( !$m->{ok}, 'action_migrate_to_local: a fetched body binding fp' );
        is( $m->{kind} // '', 'form-bind-refused', '...as form-bind-refused' );
        ok( -e "$d/sites/alpha/remote.url" && !-e "$d/sites/alpha/remote.md", '...and the .url page stands' );
    }

    local $Lazysite::Manager::Files::CALLER_SCOPES = [];
    ok( Lazysite::Manager::Files::action_save( 'sites/alpha/hook.md', 'alice', page('fp'), undef )->{ok},
        'a grant naming no scope saves it' );
};

done_testing();
