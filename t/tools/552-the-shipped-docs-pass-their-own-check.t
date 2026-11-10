#!/usr/bin/perl
# n799 (SM1420): the docs that ship with the engine pass `lazysite check`'s own
# page-title rules.
#
# A site that serves the shipped docs under /docs/ was told by its own check that
# four titles were each shared by two shipped pages, and that two shipped pages had
# no description. The rules are the check's (SM1357: no two public pages of a domain
# share a title; every one has a description) - this test does not restate them. It
# lays the whole shipped docs tree under /docs/ of a scratch site and runs the check
# itself, so a new shipped page that breaks either rule fails here, not on a deploy.
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use File::Copy qw(copy);
use File::Find ();
use FindBin;
use lib "$FindBin::Bin/../lib";
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(repo_root site_tempdir);

my $root   = repo_root();
my $script = "$root/tools/lazysite-check.pl";
my $docs   = "$root/starter/lazysite/templates/docs";
plan skip_all => 'lazysite-check.pl missing' unless -f $script;
plan skip_all => 'shipped docs missing'      unless -d $docs;

my $d = site_tempdir();
make_path("$d/lazysite/$_") for qw(auth cache logs manager);
open my $fh, '>', "$d/lazysite/lazysite.conf" or die "conf: $!";
print {$fh} "site_name: Docs\nsite_url: https://docs.example\n";
close $fh;
File::Find::find(
    {   no_chdir => 1,
        wanted   => sub {
            return unless -f $_;
            my $rel = substr $File::Find::name, length($docs) + 1;
            make_path( "$d/docs/" . ( $rel =~ m{(.*)/} ? $1 : '' ) );
            copy( $File::Find::name, "$d/docs/$rel" ) or die "copy $rel: $!";
        }
    },
    $docs
);

my $out = qx($^X \Q$script\E --docroot \Q$d\E 2>&1);

unlike( $out, qr/title\(s\) are shared by more than one public page: [^\n]*/,
    'no two shipped pages share a title' )
    or diag( ( $out =~ /^(.*title\(s\) are shared.*)$/m )[0] // $out );
unlike( $out, qr/public page\(s\) have no description: [^\n]*/,
    'every shipped page has a description' )
    or diag( ( $out =~ /^(.*have no description.*)$/m )[0] // $out );
like( $out, qr/public page\(s\), each with a title and a description of its own/,
    'the check ran over the shipped pages and passed' );

done_testing;
