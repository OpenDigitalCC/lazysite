#!/usr/bin/perl
# SM1150 (OOM Lab L-7) and the guide for SM1145, SM1146, SM1149: starter/docs/
# odoo.md said `credential: session` was "not available yet" while the lab's CRM
# ran entirely on it. A guide that is wrong in that direction sends a reader to
# build what exists, so the page is held to the code:
#
#   * `credential: session` is documented, and no longer in "Not available yet";
#   * the names it gives are the names the code uses (the two cookies, the
#     sign-in refusals, the batch cap), read from the code, not copied;
#   * the CA setting, `?csrf=1`'s identity and the batch are in it.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../../lib";
use lib "$FindBin::Bin/../../../lib";
use TestHelper qw(repo_root);
use Lazysite::Odoo::Session  ();
use Lazysite::Odoo::Identity ();

my $root = repo_root();
my $doc  = do { open my $fh, '<', "$root/starter/docs/odoo.md" or die $!; local $/; <$fh> };

my ($not_yet) = $doc =~ /^## Not available yet\n(.*?)(?:\n## |\z)/ms;
ok( defined $not_yet, 'the guide has its "Not available yet" list' );
unlike( $not_yet // '', qr/credential: session|signing in to Odoo with their own/i, '`credential: session` is not in it' );
like( $doc, qr/^## A person's own Odoo account \(`credential: session`\)$/m, 'it has a section of its own' );
like( $doc, qr/^\s*credential: session$/m, 'with an example binding that uses it' );

like( $doc, qr/`\Q$Lazysite::Odoo::Session::COOKIE\E`/,  'the credential cookie is named as the code names it' );
like( $doc, qr/`\Q$Lazysite::Odoo::Identity::COOKIE\E`/, 'and the identity cookie' );
for my $kind (qw(signin-required signin-refused two-factor)) {
    like( $doc, qr/`\Q$kind\E`/, "the refusal $kind is named" );
}

{
    local $0 = 'x';
    require "$root/lazysite-odoo.pl";
    no warnings 'once';
    like( $doc, qr/At most \*\*\Q$main::MAX_BATCH\E\*\* calls/, "the batch cap in the guide is the code's ($main::MAX_BATCH)" );
}

like( $doc, qr/`odoo_ca_file`/, 'the CA setting is documented' );
like( $doc, qr/identity: \{name\}/, '`?csrf=1`\'s identity is documented' );
like( $doc, qr/`POST \{calls: \[/, 'and the batch' );
like( $doc, qr/data-ls-odoo-name/, 'and the name element' );

done_testing;
