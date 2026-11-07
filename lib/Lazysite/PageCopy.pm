package Lazysite::PageCopy;

# SM1354 (ruling 155): WHERE A PAGE'S COPY LIVES, AS A PATH RULE, and nothing else.
#
# A page is copied, the copy is changed, and publishing puts the copy over the
# page. The copy lives in the engine tree at lazysite/copies/pages/<page path>:
# lazysite/copies/pages/about.md is the copy of about.md, and
# lazysite/copies/pages/example.org/menu.md the copy of example.org/menu.md.
#
# WHY THERE. The engine tree is never served: the processor renders pages from
# the content tree, so a copy has no public URL, is in no navigation (a nav
# names URLs), no search index or sitemap (both walk the content tree and skip
# lazysite/), and no page cache (a cache entry is written for a rendered URL,
# and a copy is only ever rendered as a draft, which writes nothing). It is
# kept out of content history too (Lazysite::Git @EXCLUDE, and action_save
# records no commit for it), so discarding a copy leaves nothing behind.
#
# WHY A PATH AT ALL. A copy is edited like any page - read_file, write_file,
# replace_text, validate_page, the manager's editor - and those all take a
# path. The path's three rules follow the page, never the folder the copy sits
# in, and they are answered here so every door asks the same function:
#
#   who may read or write it  - whoever may WRITE the page (Auth::Acl maps the
#                               copy to its page, in write mode, for both)
#   which scope it is in      - the page's (the MCP and control-API scope
#                               checks ask scope_path before skipping lazysite/)
#   what capability reaches it - manage_content (Manager::Common's carve-out)
#
# Pure: no I/O, no other module, so Auth::Acl and Manager::Common can ask it
# without a load-order loop. The copy records and the verbs are
# Lazysite::Manager::PageCopy's.

use strict;
use warnings;
use Exporter 'import';

our @EXPORT_OK = qw(copy_prefix copy_of original_of under_copies scope_path);

my $PREFIX = 'lazysite/copies/pages/';

sub copy_prefix { return $PREFIX }

sub _norm {
    my ($p) = @_;
    return undef unless defined $p;
    ( my $r = $p ) =~ s{^/+}{};
    $r =~ s{/+}{/}g;
    return $r;
}

# The copy path for a page path (docroot-relative, with or without the leading
# slash), or undef for a path that is not a page.
sub copy_of {
    my ($page) = @_;
    my $r = _norm($page);
    return undef unless defined $r && length $r && $r =~ /\.md\z/;
    return undef if $r =~ m{\Alazysite(?:/|\z)};
    return undef if $r =~ m{(?:\A|/)\.\.(?:/|\z)};
    return $PREFIX . $r;
}

# The page a copy path stands for, or undef when the path is not a page's copy.
sub original_of {
    my ($path) = @_;
    my $r = _norm($path);
    return undef unless defined $r && index( $r, $PREFIX ) == 0;
    my $page = substr( $r, length $PREFIX );
    return undef unless length $page && $page =~ /\.md\z/;
    return undef if $page =~ m{\Alazysite(?:/|\z)};
    return undef if $page =~ m{(?:\A|/)\.\.(?:/|\z)};
    return $page;
}

# Is this path in the copies folder at all (the folder itself included)?
sub under_copies {
    my ($path) = @_;
    my $r = _norm($path);
    return 0 unless defined $r;
    $r =~ s{/+\z}{};
    return 1 if "$r/" eq $PREFIX;
    return index( $r, $PREFIX ) == 0 ? 1 : 0;
}

# The path a scope check is asked about: the page, for a copy; the path itself
# otherwise.
sub scope_path {
    my ($path) = @_;
    my $page = original_of($path);
    return defined $page ? $page : $path;
}

1;
