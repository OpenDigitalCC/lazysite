#!/usr/bin/perl
# SM1424 (n804): A `description:` KEY IS READ BY NOTHING, AND THE CHECK SAYS SO.
#
# The engine publishes meta_desc, else subtitle (render.pm page_meta_desc, the
# registries, llms.txt). A page with `description:` in its front matter was listed
# by `lazysite check` as having no description, with a remedy that named subtitle:
# and meta_desc: and not the key the author had written. No third spelling is
# added (one concept, one name); the check's line and validate_page now say the key
# is not read and which two are.
#
# With the change reverted the check line and the validation warning are absent.
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../lib";
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(repo_root site_tempdir);
use Lazysite::Validate ();

my $script = repo_root() . '/tools/lazysite-check.pl';
sub spit { my ( $p, $t ) = @_; open my $fh, '>', $p or die "$p: $!"; print {$fh} $t; close $fh; return }

my $doc = site_tempdir();
make_path("$doc/lazysite/$_") for qw(auth cache logs manager);
spit( "$doc/lazysite/lazysite.conf", "site_name: T\n" );
spit( "$doc/index.md",   "---\ntitle: Home\nsubtitle: Welcome\n---\nH\n" );
spit( "$doc/wrote.md",   "---\ntitle: Wrote\ndescription: Written under the wrong key\n---\nW\n" );
spit( "$doc/bare.md",    "---\ntitle: Bare\n---\nB\n" );
my $out = qx($^X \Q$script\E --docroot \Q$doc\E 2>&1);
like( $out, qr/public page\(s\) have no description: [^\n]*\/wrote/, 'the page is still listed: the engine does not read the key' ) or diag $out;
like( $out, qr/description: is not read by the engine \(\/wrote carry it\); subtitle: and meta_desc: are/,
    'and the line says the key is not read and which two are' );
unlike( $out, qr/\(\/[^)]*bare[^)]* carry it\)/, 'a page that never wrote the key is not blamed for it' );

my $r = Lazysite::Validate::validate_content(
    content => "---\ntitle: T\ndescription: x\n---\nBody\n", path => '/t.md', docroot => $doc, lazysite_dir => "$doc/lazysite" );
my ($w) = grep { $_->{kind} eq 'description-not-read' } @{ $r->{warnings} };
ok( $w, 'validate_page warns when the page carries description:' ) or diag explain $r;
like( $w->{message} // '', qr/not read.*subtitle: or meta_desc:/, 'saying which keys are read' );
$r = Lazysite::Validate::validate_content(
    content => "---\ntitle: T\nsubtitle: x\n---\nBody\n", path => '/t.md', docroot => $doc, lazysite_dir => "$doc/lazysite" );
ok( !( grep { $_->{kind} eq 'description-not-read' } @{ $r->{warnings} } ), 'and says nothing of a page that uses subtitle:' );

done_testing;
