#!/usr/bin/perl
# SM072: the offline-bundle apply tool - deny enforcement, traversal
# protection, dry-run vs apply. SM852: and where each file lands - a page in a
# protected section goes to the private store, an engine-tree file to the
# engine tree wherever it lives.
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root site_tempdir);

my $tool = repo_root() . '/tools/lazysite-bundle-apply.pl';

sub spit { my ( $p, $t ) = @_; open my $fh, '>', $p or die "$p: $!"; print {$fh} $t; close $fh; return }
sub slurp { my ($p) = @_; open my $fh, '<', $p or return ''; local $/; my $t = <$fh>; close $fh; return $t }

subtest 'deny, traversal, dry run and apply' => sub {
    my $d = site_tempdir();
    mkdir "$d/lazysite";
    my $bundle = "$d/bundle.json";
    spit( $bundle, '{"lazysite_bundle":1,"post":["clear-cache"],"files":['
            . '{"path":"about.md","content":"hi\n"},'
            . '{"path":"lazysite/layouts/x/layout.tt","content":"y"},'
            . '{"path":"lazysite/auth/users","content":"evil"},'
            . '{"path":"../escape","content":"z"}]}' );

    my $dry = qx($^X \Q$tool\E --docroot \Q$d\E \Q$bundle\E 2>&1);
    like( $dry, qr/2 allowed, 2 denied/,  'dry run counts allowed/denied' );
    like( $dry, qr/DENIED[^\n]*lazysite/, 'a denied path is reported' );
    like( $dry, qr/clear the page cache/, 'post-extract action reported' );
    unlike( $dry, qr/-name '\*\.html' -delete/,
        'and it no longer suggests deleting every .html - a legacy page or partial is content' );
    ok( !-e "$d/about.md", 'dry run writes nothing' );

    qx($^X \Q$tool\E --docroot \Q$d\E --apply \Q$bundle\E 2>&1);
    ok( -f "$d/about.md",                      'allowed content file written' );
    ok( -f "$d/lazysite/layouts/x/layout.tt",  'nested allowed file written' );
    ok( !-e "$d/lazysite/auth/users",          'denied path NOT written' );
    ok( !-e "$d/escape" && !-e "$d/../escape", 'traversal path NOT written' );
};

subtest 'a page in a protected section is written where the section is' => sub {
    my $d    = site_tempdir();
    my $priv = "$d-lazysite-private";
    make_path( "$d/lazysite", "$priv/members" );
    spit( "$priv/members/handbook.md", "OLD PROTECTED\n" );
    my $bundle = "$d/bundle.json";
    spit( $bundle, '{"lazysite_bundle":1,"files":['
            . '{"path":"members/handbook.md","content":"NEW PROTECTED\n"},'
            . '{"path":"members/new.md","content":"ANOTHER\n"}]}' );

    my $dry = qx($^X \Q$tool\E --docroot \Q$d\E \Q$bundle\E 2>&1);
    like( $dry, qr/\[overwrite, protected\] members\/handbook\.md/,
        'the dry run calls an existing protected page an overwrite, and says it is protected' );
    like( $dry, qr/\[create, protected\] members\/new\.md/, 'and a new page in the section a protected create' );

    qx($^X \Q$tool\E --docroot \Q$d\E --apply \Q$bundle\E 2>&1);
    like( slurp("$priv/members/handbook.md"), qr/NEW PROTECTED/, 'the protected page is updated in the store' );
    ok( -f "$priv/members/new.md", 'the new page lands in the store with its section' );
    ok( !-e "$d/members",          'and nothing reaches the served tree' );
};

subtest 'an engine-tree file goes to the engine tree, wherever it lives' => sub {
    my $d  = site_tempdir();
    my $lz = "$d-lazysite";    # a migrated site: the engine tree beside the docroot
    make_path($lz);
    my $bundle = "$d/bundle.json";
    spit( $bundle, '{"lazysite_bundle":1,"files":[{"path":"lazysite/layouts/x/layout.tt","content":"y"}]}' );
    qx($^X \Q$tool\E --docroot \Q$d\E --apply \Q$bundle\E 2>&1);
    ok( -f "$lz/layouts/x/layout.tt", 'the layout is written into the engine tree beside the docroot' );
    ok( !-e "$d/lazysite", 'and no stray engine tree is made inside the served one' );
};

done_testing();
