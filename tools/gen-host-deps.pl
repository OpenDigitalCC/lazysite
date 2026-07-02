#!/usr/bin/perl
# gen-host-deps.pl - generate docs/reference/host-dependencies.md from the
# authoritative dependency metadata in dist/config/sbom-deps.json (SM126 D).
#
# The host-dependency doc is DERIVED, never hand-edited, so it cannot drift from
# the SBOM data the release process already maintains. Regenerate with:
#
#   perl tools/gen-host-deps.pl > docs/reference/host-dependencies.md
#
# t/tools/25-host-deps.t fails if the committed doc differs from this output.
use strict;
use warnings;
use Cwd qw(abs_path);
use File::Basename qw(dirname);
use JSON::PP ();

my $root = dirname( dirname( abs_path($0) ) );
my $deps_path = "$root/dist/config/sbom-deps.json";
open my $fh, '<', $deps_path or die "gen-host-deps: cannot read $deps_path: $!\n";
my $json = do { local $/; <$fh> };
close $fh;
my $data = JSON::PP->new->decode($json);

my $modules = $data->{modules} || {};
my $env     = $data->{environment} || [];

# Non-core modules, keyed by Debian package (the install unit). One package can
# back several modules (Template + Template::Parser -> libtemplate-perl).
my %pkg;    # debian_pkg => { modules => [...], used_by => {...} }
for my $mod ( sort keys %{$modules} ) {
    my $m = $modules->{$mod};
    next if $m->{core};
    my $pkg = $m->{debian_pkg} // '';
    next unless length $pkg;
    push @{ $pkg{$pkg}{modules} }, $mod;
    $pkg{$pkg}{used_by}{ $m->{used_by} // '' } = 1;
}

my @pkgs = sort keys %pkg;

# --- emit ---------------------------------------------------------------
my @out;
push @out, <<'FM';
---
title: "lazysite - host dependencies"
subtitle: "The OS packages a host needs, beyond core Perl"
brand: plain
standard-margins: true
---
FM

push @out, <<'INTRO';

**Generated file - do not edit by hand.** Produced from
`dist/config/sbom-deps.json` by `tools/gen-host-deps.pl`; that JSON is the
authoritative machine-readable list. To check a live host instead of reading
this snapshot, run `lazysite-check.pl --dependencies`, which reports which of
these are present and prints the install line for whatever is missing.

## What you need

lazysite runs on core Perl plus a small set of packaged Perl modules. The core
modules ship with the `perl` package (Debian: `perl-modules-*`); only the
non-core packages below must be installed explicitly. Package names are Debian;
`sbom-deps.json` also carries the RHEL and Alpine equivalents.

On Debian or Ubuntu, install them all with:
INTRO

push @out, "\n```bash\nsudo apt-get install \\\n";
push @out, join( " \\\n", map { "    $_" } @pkgs );
push @out, "\n```\n";

push @out, "\n## Packages\n\n";
push @out, "```datatable\n";
push @out, "columns: Package | Perl module(s) | Enables\n";
push @out, "widths: 5cm | 4.5cm | X\n";
push @out, "bold: 1\n";
push @out, "tone: medium\n";
push @out, "text: 3\n";
push @out, "---\n";
for my $pkg (@pkgs) {
    my $mods = join( ', ', @{ $pkg{$pkg}{modules} } );
    my $uses = join( '; ', sort grep { length } keys %{ $pkg{$pkg}{used_by} } );
    push @out, "$pkg | $mods | $uses\n";
}
push @out, "```\n";

push @out, "\n## Runtime environment\n\n";
for my $e ( @{$env} ) {
    my $name = $e->{name} // '';
    my $desc = $e->{description} // '';
    push @out, "$name\n: $desc\n\n";
}

push @out, <<'FOOT';
## Core modules

The remaining modules lazysite uses (`Digest::SHA`, `File::*`, `POSIX`, `Cwd`,
`Encode`, `JSON::PP`, `MIME::Base64`, `Socket`, `IO::Socket::INET`, and the
rest) are core Perl - present wherever Perl is. The full list, with per-module
purpose and licence, is in `dist/config/sbom-deps.json`.
FOOT

print join( '', @out );
