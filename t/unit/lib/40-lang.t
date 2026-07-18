#!/usr/bin/perl
# SM179: Lazysite::Lang - language-set membership and translation-coverage status.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use lib "$FindBin::Bin/../../../lib";
use Lazysite::Lang qw(set_members lang_status);

my $conf = <<'CONF';
site_name: T
lang: en
lang_group: providers
site_url: https://en.example
content_root: sites/en
alias_hosts: de.example, fr.example
alias.de.example.lang: de
alias.de.example.lang_group: providers
alias.de.example.content_root: sites/de
alias.fr.example.lang: fr
alias.fr.example.lang_group: providers
alias.fr.example.content_root: sites/fr
CONF

# --- set_members --------------------------------------------------------------
my @m = set_members( $conf, 'providers' );
is( scalar(@m), 3, 'three members in the set' );
my ($src) = grep { $_->{source} } @m;
is( $src->{host}, '',   'the base host is the source' );
is( $src->{lang}, 'en', 'source language is en' );
is( scalar( grep { $_->{source} } @m ), 1, 'exactly one source member' );
is_deeply( [ sort map { $_->{lang} } @m ], [qw(de en fr)], 'languages de/en/fr' );

is( scalar( () = set_members( $conf, 'nosuch' ) ), 0, 'unknown group => no set' );
is( scalar( () = set_members( "site_name: T\nlang: en\n", 'providers' ) ),
    0, 'a lone host is not a set' );

# --- lang_status: build roots and vary each file's state ----------------------
my $d = tempdir( CLEANUP => 1 );
make_path( "$d/sites/en", "$d/sites/de", "$d/sites/fr" );

# Source (en) has three pages.
for my $f (qw(index about contact)) {
    open my $fh, '>', "$d/sites/en/$f.md" or die $!;
    print $fh "---\ntitle: $f\n---\n\nen $f\n";
    close $fh;
}

# de: index current (written after source), about stale (older), contact missing.
open my $di, '>', "$d/sites/de/index.md" or die $!;
print $di "---\ntitle: index\n---\n\nde index\n";
close $di;
open my $da, '>', "$d/sites/de/about.md" or die $!;
print $da "---\ntitle: about\n---\n\nde about\n";
close $da;
# Make de/about older than en/about, and de/index newer.
my $now = ( stat "$d/sites/en/index.md" )[9];
utime $now - 100, $now - 100, "$d/sites/de/about.md";
utime $now + 100, $now + 100, "$d/sites/de/index.md";

# fr: has all three but as fresh copies (all current by mtime).
for my $f (qw(index about contact)) {
    open my $fh, '>', "$d/sites/fr/$f.md" or die $!;
    print $fh "---\ntitle: $f\n---\n\nfr $f\n";
    close $fh;
    utime $now + 200, $now + 200, "$d/sites/fr/$f.md";
}

my $st = lang_status( docroot => $d, conf_text => $conf, group => 'providers' );
is( $st->{members},        3,  'status: three members' );
is( $st->{source}{lang},   'en', 'status: source lang en' );
is( $st->{source}{files},  3,  'status: three source files' );
is( scalar @{ $st->{roots} }, 2, 'status: two non-source roots' );

my %by = map { $_->{lang} => $_ } @{ $st->{roots} };
is( $by{de}{current}, 1, 'de: one current (index)' );
is( $by{de}{stale},   1, 'de: one stale (about)' );
is( $by{de}{missing}, 1, 'de: one missing (contact)' );
is( $by{de}{total},   3, 'de: total tracks the source count' );
is( $by{fr}{current}, 3, 'fr: all three current' );
is( $by{fr}{missing}, 0, 'fr: none missing' );

# --- translated_from gives exact staleness ------------------------------------
# Pin de/index to the CURRENT source hash => current even if mtimes said stale.
use Digest::SHA qw(sha256_hex);
open my $srch, '<:raw', "$d/sites/en/index.md" or die $!;
my $bytes = do { local $/; <$srch> };
close $srch;
my $hash = sha256_hex($bytes);
open my $pin, '>', "$d/sites/de/index.md" or die $!;
print $pin "---\ntitle: index\ntranslated_from: $hash\n---\n\nde index\n";
close $pin;
utime $now - 500, $now - 500, "$d/sites/de/index.md";    # older, but hash matches
my $st2 = lang_status( docroot => $d, conf_text => $conf, group => 'providers' );
my %by2 = map { $_->{lang} => $_ } @{ $st2->{roots} };
my ($idx) = grep { $_->{path} eq 'index.md' } @{ $by2{de}{files} };
is( $idx->{status}, 'current', 'translated_from matching the source hash => current' );

# A stale hash marks it stale regardless of mtime.
open my $pin2, '>', "$d/sites/de/index.md" or die $!;
print $pin2 "---\ntitle: index\ntranslated_from: deadbeef\n---\n\nde index\n";
close $pin2;
utime $now + 999, $now + 999, "$d/sites/de/index.md";    # newer, but hash mismatched
my $st3 = lang_status( docroot => $d, conf_text => $conf, group => 'providers' );
my %by3 = map { $_->{lang} => $_ } @{ $st3->{roots} };
my ($idx3) = grep { $_->{path} eq 'index.md' } @{ $by3{de}{files} };
is( $idx3->{status}, 'stale', 'translated_from not matching the source hash => stale' );

done_testing;
