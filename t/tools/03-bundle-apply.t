#!/usr/bin/perl
# SM072: the offline-bundle apply tool - deny enforcement, traversal
# protection, dry-run vs apply.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root);

my $tool = repo_root() . '/tools/lazysite-bundle-apply.pl';
my $d    = tempdir( CLEANUP => 1 );
mkdir "$d/lazysite";

my $bundle = "$d/bundle.json";
open my $b, '>', $bundle or die $!;
print $b '{"lazysite_bundle":1,"post":["clear-cache"],"files":['
    . '{"path":"about.md","content":"hi\n"},'
    . '{"path":"lazysite/layouts/x/layout.tt","content":"y"},'
    . '{"path":"lazysite/auth/users","content":"evil"},'
    . '{"path":"../escape","content":"z"}]}';
close $b;

# --- dry run audits, writes nothing ------------------------------------
my $dry = qx($^X \Q$tool\E --docroot \Q$d\E \Q$bundle\E 2>&1);
like( $dry, qr/2 allowed, 2 denied/,            'dry run counts allowed/denied' );
like( $dry, qr/DENIED[^\n]*lazysite/,            'a denied path is reported' );
like( $dry, qr/clear the HTML cache/,            'post-extract action reported' );
ok( !-e "$d/about.md",                           'dry run writes nothing' );

# --- apply writes only the in-scope files ------------------------------
qx($^X \Q$tool\E --docroot \Q$d\E --apply \Q$bundle\E 2>&1);
ok( -f "$d/about.md",                            'allowed content file written' );
ok( -f "$d/lazysite/layouts/x/layout.tt",        'nested allowed file written' );
ok( !-e "$d/lazysite/auth/users",                'denied path NOT written' );
ok( !-e "$d/escape" && !-e "$d/../escape",        'traversal path NOT written' );

done_testing();
