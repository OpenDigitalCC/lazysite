#!/usr/bin/perl
# SM1251: THE STARTER /contact.md LOSES ITS INLINE <style> ON EXISTING SITES TOO.
#
# Up to 0.16.0 the shipped contact page opened with a 60-line <style> block
# that came after any theme's stylesheet and beat its form rules on that one
# page (theunited.community, 2026-10-21). The rules moved to the fallback
# chrome. Removing them from the starter only helps a NEW site unless the
# upgrade carries the new page to the sites that have the old one - which the
# seed rule (ADR 0004) should do for an unmodified copy and must never do for
# a customised one. That is asserted here by running install.pl, not assumed:
#
#   - a site holding the 0.16.0 page exactly as shipped is upgraded to the new
#     page, with no <style> in it;
#   - a site that changed its copy keeps every byte of it.
#
# The 0.16.0 page is embedded VERBATIM and its checksum asserted, so the
# fixture is the file real sites have rather than something shaped like it.
use strict;
use warnings;
use Test::More;
use File::Path     qw(make_path);
use File::Temp     qw(tempdir);
use Digest::SHA    qw(sha256_hex);
use JSON::PP       qw(decode_json encode_json);
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root repo_manifest_guard);

my $ROOT     = repo_root();
my $MF_GUARD = repo_manifest_guard();

my $OLD = <<'END_OLD_CONTACT';
---
provenance: lazysite-starter
starter_role: content
title: Contact
subtitle: Get in touch.
form: contact
register:
  - sitemap.xml
  - llms.txt
---

<style>
  .lazysite-form {
    max-width: min(480px, 100%);
    margin: 1rem 0;
    box-sizing: border-box;
  }
  .lazysite-form .form-field {
    display: grid;
    grid-template-columns: 7rem 1fr;
    gap: 0.6rem 0.75rem;
    align-items: start;
    margin-bottom: 0.6rem;
  }
  .lazysite-form .form-field label {
    text-align: right;
    padding-top: 0.45rem;
  }
  .lazysite-form input[type="text"],
  .lazysite-form input[type="email"],
  .lazysite-form input[type="tel"],
  .lazysite-form input[type="number"],
  .lazysite-form textarea,
  .lazysite-form select {
    width: 100%;
    max-width: 100%;
    box-sizing: border-box;
    padding: 0.4rem 0.55rem;
    border: 1px solid #ccc;
    border-radius: 3px;
    font: inherit;
  }
  .lazysite-form textarea {
    min-height: 6rem;
    resize: vertical;
  }
  .lazysite-form input:focus,
  .lazysite-form textarea:focus,
  .lazysite-form select:focus {
    outline: 2px solid #0056b3;
    outline-offset: 0;
  }
  .lazysite-form .required {
    color: #888;
    font-weight: normal;
  }
  .lazysite-form .form-field.form-submit > button {
    grid-column: 2;
    padding: 0.45rem 1.25rem;
    font: inherit;
    cursor: pointer;
    border: 1px solid #0056b3;
    background: #0056b3;
    color: #fff;
    border-radius: 3px;
  }
  .lazysite-form .form-field.form-submit > button:hover {
    background: #003d80;
    border-color: #003d80;
  }
  .lazysite-form .form-status {
    margin-top: 0.5rem;
    font-size: 0.9rem;
    color: #666;
  }
</style>

::: form
name    | Your name       | required max:200
email   | Email address   | required email max:254
phone   | Phone number    | optional max:30
message | Your message    | required textarea max:5000
submit  | Send message
:::
END_OLD_CONTACT

is( sha256_hex($OLD), '35ebc3d34093e3568bf03cc3613ec58494dccc2cb64b5a33e94727ed2f0180ae',
    'the fixture is the 0.16.0 starter contact.md byte for byte' );
like( $OLD, qr/<style>/, 'and carries the <style> block this change removes' );

sub slurp { open my $f, '<:raw', $_[0] or die "$_[0]: $!"; local $/; my $t = <$f>; close $f; $t }
sub spit  { my ( $p, $t ) = @_; open my $f, '>:raw', $p or die "$p: $!"; print {$f} $t; close $f }

my $SHIPPED = slurp("$ROOT/starter/contact.md");
unlike( $SHIPPED, qr/<style/i, 'the starter contact page ships with no <style> block' );

sub install {
    my ( $docroot, $cgibin, $mode ) = @_;
    local $ENV{PERL5LIB};
    delete $ENV{PERL5LIB};
    my @cmd = ( $^X, "$ROOT/install.pl", '--docroot', $docroot, '--cgibin', $cgibin,
        '--mode', $mode, '--serving-group', ( getgrgid( $) + 0 ) // ( $) + 0 ) ) );
    my $cmd = join ' ', map {quotemeta} @cmd;
    my $out = `$cmd 2>&1`;
    return ( $? >> 8, $out );
}

# A site as 0.16.0 left it: its contact page is $page, and the install state
# records the 0.16.0 page as what was installed there. Then put it on edge and
# backdate the state, so the next run is the upgrade a release brings.
sub old_site {
    my ($page) = @_;
    my $dir = tempdir( 'lazysite-sm1251-XXXXXX', TMPDIR => 1, CLEANUP => 1 );
    my ( $docroot, $cgibin ) = ( "$dir/site", "$dir/cgi-bin" );
    make_path( $docroot, $cgibin );
    my ( $rc, $out ) = install( $docroot, $cgibin, 'provision' );
    is( $rc, 0, 'the site is provisioned' ) or diag $out;

    spit( "$docroot/contact.md", $page );
    my $sp    = "$docroot/lazysite/.install-state.json";
    my $state = decode_json( slurp($sp) );
    ok( exists $state->{files}{"$docroot/contact.md"}, 'the state tracks contact.md' );
    $state->{files}{"$docroot/contact.md"} = 'sha256:' . sha256_hex($OLD);
    $state->{version} = '0.0.1';
    spit( $sp, encode_json($state) );

    my $conf = "$docroot/lazysite/lazysite.conf";
    my $c    = slurp($conf);
    $c =~ s/^update_channel:.*$/update_channel: edge/m or $c .= "update_channel: edge\n";
    spit( $conf, $c );
    return ( $docroot, $cgibin );
}

subtest 'an unmodified 0.16.0 contact page is refreshed by the upgrade' => sub {
    my ( $docroot, $cgibin ) = old_site($OLD);
    my ( $rc, $out ) = install( $docroot, $cgibin, 'upgrade' );
    is( $rc, 0, 'the upgrade ran' ) or diag $out;
    my $now = slurp("$docroot/contact.md");
    is( $now, $SHIPPED, 'contact.md is now the shipped page' );
    unlike( $now, qr/<style/i, 'and has no <style> block' );
    unlike( $out, qr{- \Q$docroot\E/contact\.md}, 'it is not listed as preserved' );
};

subtest 'a customised contact page is never touched' => sub {
    my $mine = $OLD =~ s/subtitle: Get in touch\./subtitle: Write to us./r;
    my ( $docroot, $cgibin ) = old_site($mine);
    my ( $rc, $out ) = install( $docroot, $cgibin, 'upgrade' );
    is( $rc, 0, 'the upgrade ran' ) or diag $out;
    is( slurp("$docroot/contact.md"), $mine, 'the customised contact.md is byte-identical' );
    like( $out, qr{- \Q$docroot\E/contact\.md}, 'and the upgrade says it preserved it' );
};

done_testing();
