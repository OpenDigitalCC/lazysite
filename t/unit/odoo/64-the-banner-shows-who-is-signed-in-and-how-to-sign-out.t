#!/usr/bin/perl
# SM1160 (ruling 4), the browser half: the "Signed in as <name>" banner the default layout
# renders on a site whose Odoo sign-in is the site sign-in (t/unit/odoo/63 holds the layout
# and the server). The helper shows the signed-in part, with its name and sign-out link,
# when the token fetch every page makes names someone, and the sign-in link when it does
# not - from the same fetch, so the banner costs no Odoo call.
use strict;
use warnings;
use Test::More;
use JSON::PP qw(decode_json);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(repo_root);

my $root  = repo_root();
my $asset = "$root/starter/assets/lazysite-odoo.js";
my $node  = `sh -c 'command -v node || command -v nodejs' 2>/dev/null`;
chomp $node;
plan skip_all => 'node is not installed' unless length $node && -x $node;

my $out = `$node "$root/t/lib/odoo-helper-harness.js" "$asset" 2>&1`;
my $f   = eval { decode_json($out) };
ok( $f && !$f->{error}, 'the behaviour harness ran' ) or BAIL_OUT("harness: $out");

my $b = $f->{banner};
is( $b->{in_name}, 'Jane', 'signed in: the name goes in, as text' );
ok( !$b->{in_hidden},   'the "Signed in as" part (with the sign-out link) is shown' );
ok( $b->{in_out_hidden}, 'and the sign-in link is hidden' );
ok( $b->{out_hidden_in}, 'nobody signed in: the "Signed in as" part stays hidden' );
ok( !$b->{out_hidden_out}, 'and the sign-in link is shown' );

done_testing;
