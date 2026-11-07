package Lazysite::Extensions;

# SM1142 S1: WHERE AN EXTENSION'S SCRIPT IS, ANSWERED ONCE.
#
# Eleven places used to find a script on disk, each with its own list of
# candidates: the registry scan, the daemon's stats job, the handler runner, the
# notifier, the PDF render, the auth CGI's setup mail, MCP's stats export, the
# manager's tool path, the dev server, the bench. Three fell back to the
# package's copy and the rest did not, two still looked inside the docroot, and
# moving the directory meant finding all eleven. They ask here now, and
# t/lint/306 refuses a twelfth list.
#
# THE ORDER: the dev server's --extensions directories (SM1222; empty on an
# installed engine), then `extensions/` under each install root the caller
# names, in the caller's order, then the package's /usr/share/lazysite/extensions.
# An install root is the directory the site's `extensions/`, `tools/` and `lib/`
# sit in: the docroot's parent on a deployed site, the repository in a checkout.
#
# install.pl is the one reader that cannot ask (SM767: it loads no Lazysite
# module) and names the directory itself, through its classification
# placeholder.

use strict;
use warnings;
use Exporter 'import';
use Lazysite::Paths ();

our @EXPORT_OK = qw(locate extensions_dir registry_key payload_lib add_payload_lib engine_root require_payload);

# The directory's name under an install root, and the package's copy. The
# registry key a site's lazysite.conf lists is the same name and the file:
# `extensions/<file>.pl` (R1).
our $DIR      = 'extensions';
our $PACKAGED = '/usr/share/lazysite/extensions';

# A file name, never a path: a name with a separator or a leading dot could
# walk out of the directory it is looked up in.
sub _plain_name {
    my ($file) = @_;
    return defined $file && $file =~ /\A[A-Za-z0-9_-][A-Za-z0-9_.-]*\z/ ? 1 : 0;
}

# The site's extension directory under an install root.
sub extensions_dir {
    my ($root) = @_;
    return "$root/$DIR";
}

# What lazysite.conf lists for an extension's file.
sub registry_key {
    my ($file) = @_;
    return "$DIR/$file";
}

# The first readable copy of $file, or undef. @roots are install roots, in the
# order the caller trusts them; an undefined or empty one is skipped.
sub locate {
    my ( $file, @roots ) = @_;
    return undef unless _plain_name($file);
    for my $d ( Lazysite::Paths::dev_extension_dirs() ) {
        my $p = "$d/$file";
        return $p if -f $p && !-l $p;
    }
    for my $root ( grep { defined && length } @roots ) {
        my $p = extensions_dir($root) . "/$file";
        return $p if -f $p;
    }
    my $p = "$PACKAGED/$file";
    return -f $p ? $p : undef;
}

# SM1369 X1: AN EXTENSION'S PAYLOAD sits beside its descriptor, in a directory
# named for it: extensions/odoo.pl and extensions/odoo/ (lib/, assets/,
# templates/, docs/, t/, tools/). The descriptor keeps its place, so the
# registry key a site's lazysite.conf lists does not change.
#
# The payload's lib, or undef: a real directory at each step, never a link, so
# a link planted beside a descriptor cannot point the loader at code elsewhere.
sub payload_lib {
    my ($descriptor) = @_;
    return undef unless defined $descriptor && $descriptor =~ m{\A(.+)/([A-Za-z0-9_-][A-Za-z0-9_-]*)\.pl\z};
    my $payload = "$1/$2";
    return undef if -l $payload || !-d $payload;
    my $lib = "$payload/lib";
    return undef if -l $lib || !-d $lib;
    return $lib;
}

# THE ONE RULE that puts an extension's payload lib on @INC, as t/lint/263 holds
# one rule for finding the engine's. APPENDED, never prepended: core's lib and
# the system's modules resolve first, so a payload cannot replace a module that
# already exists elsewhere, and Lazysite::Extensions::Hooks refuses a hook
# module found anywhere but the payload. The caller has checked the extension is
# enabled (Hooks::call_hook). Returns the lib, or undef when there is none.
sub add_payload_lib {
    my ($descriptor) = @_;
    my $lib = payload_lib($descriptor);
    return undef unless defined $lib;
    push @INC, $lib unless grep { !ref && $_ eq $lib } @INC;
    return $lib;
}

# SM1369 X7, part one (ruling 135): CORE'S REMAINING CALLS INTO AN EXTENSION'S
# OWN MODULES. An extension's modules live in its payload lib, never in core's
# lib/, so a hook (X2 onwards) can name them. Until each hook slice replaces the
# core lines that still call an extension's module by name (the allow-list of
# t/lint/321), those lines load it here, and only here (t/lint/335):
#
#   - THE ENGINE'S OWN COPY: the payload beside the lib this module was loaded
#     from - {DOCROOT}/../lib with {DOCROOT}/../extensions on a site, lib/ with
#     extensions/ in a checkout and in /usr/share/lazysite - so core and the
#     extension it calls always come from the same install;
#   - the payload lib goes on @INC by the one rule (add_payload_lib, appended);
#   - the module must be a file in exactly one payload lib, and nowhere else on
#     @INC: a copy an earlier release left in core's lib (an edited one the
#     upgrade keeps, with its orphan warning) would otherwise win, so it is
#     refused by name;
#   - it dies as `require` does, so a caller's `eval { require ... }` reads the
#     same. Like `require`, it loads and gates nothing else: whether the
#     extension is on is the caller's question, as it was before the move.
sub engine_root {
    my $me = $INC{'Lazysite/Extensions.pm'} or return undef;
    require Cwd;
    my $abs = Cwd::abs_path($me)                or return undef;
    $abs =~ s{/lib/Lazysite/Extensions\.pm\z}{} or return undef;
    return $abs;
}

# Every payload lib of the engine's own extensions: ( [ descriptor, lib ], ... ).
sub _engine_payloads {
    my $root = engine_root();
    return () unless defined $root;
    my $dir = extensions_dir($root);
    opendir my $dh, $dir or return ();
    my @stems = sort grep { /\A[A-Za-z0-9_-]+\z/ && -d "$dir/$_" && !-l "$dir/$_" } readdir $dh;
    closedir $dh;
    my @out;
    for my $s (@stems) {
        my $d = "$dir/$s.pl";
        next unless -f $d;
        my $lib = payload_lib($d);
        push @out, [ $d, $lib ] if defined $lib;
    }
    return @out;
}

sub require_payload {
    my ($module) = @_;
    die "require_payload: '" . ( $module // '' ) . "' is not a module name\n"
        unless defined $module && $module =~ /\A[A-Za-z_]\w*(?:::\w+)*\z/;
    ( my $rel = "$module.pm" ) =~ s{::}{/}g;
    return 1 if $INC{$rel};
    my @hit = grep { -f "$_->[1]/$rel" && !-l "$_->[1]/$rel" } _engine_payloads();
    die "Can't locate $rel in any extension's payload lib (" . ( engine_root() // 'no engine root' ) . "/extensions)\n"
        unless @hit;
    die "$rel is in more than one extension's payload lib: $hit[0][1], $hit[1][1]\n" if @hit > 1;
    my ( $descriptor, $lib ) = @{ $hit[0] };
    require Cwd;
    my $mine = Cwd::abs_path("$lib/$rel");
    for my $dir ( grep { !ref && length } @INC ) {
        next unless -e "$dir/$rel";
        my $other = Cwd::abs_path("$dir/$rel");
        next if defined $other && $other eq $mine;
        die "$rel is in the payload lib $lib and also at $dir/$rel - a copy an earlier release left "
            . "outside the extension; remove it\n";
    }
    add_payload_lib($descriptor);
    require $rel;
    return 1;
}

1;
