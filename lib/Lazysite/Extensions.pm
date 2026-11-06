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

our @EXPORT_OK = qw(locate extensions_dir registry_key payload_lib add_payload_lib);

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

1;
