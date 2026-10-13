#!/usr/bin/perl
# SM1068 (ruled 2026-10-13, "Read/draft only"): only rules that change what a
# viewer sees - a `read` list, or `draft` - govern a page. A write-only rule no
# longer makes a page per-viewer or uncacheable, and no longer leaves it out of
# scans and registries. Read lists and drafts behave exactly as before.
#
# The three predicates the processor asks, against one store holding every
# case, and the two listings built on them: the registries (_registry_hidden,
# identity-free) and a `scan:` list (_scan_hidden, as the anonymous requester).
#
# ONE process, ONE docroot, ONE identity, because the processor memoises all
# three (see t/unit/processor/61).
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use Cwd qw(realpath);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(load_processor site_tempdir);

my $docroot = realpath( site_tempdir() );
make_path( "$docroot/lazysite/auth", map {"$docroot/$_"} qw(post sec drafts mixed partials) );
sub put { my ( $p, $c ) = @_; open my $fh, '>', $p or die "$p: $!"; print {$fh} $c; close $fh; return }
put( "$docroot/lazysite/lazysite.conf", "site_name: T\nsite_url: http://localhost\n" );

my %page = (
    open_post  => 'post/open.md',      # its own write-only rule, under / write-only
    plain      => 'plain.md',          # only the / write-only rule
    read_sec   => 'sec/page.md',       # a read list on its folder
    read_owned => 'sec/owned.md',      # ... and a write-only rule of its own (SM268 H10)
    draft      => 'drafts/page.md',    # a draft folder, no read list
    draft_own  => 'drafts/owned.md',   # ... and a write-only rule of its own (SM981)
    mixed      => 'mixed/page.md',     # read list AND write list on one entry
    partial    => 'partials/foot.md',  # a partial under only the / write-only rule
);
put( "$docroot/$_", "---\ntitle: $_\nregister:\n  - sitemap.xml\n---\nbody\n" ) for values %page;

put( "$docroot/lazysite/auth/acls.json", <<'JSON' );
{
  "/":              { "owner": "root", "write": ["@sysops"] },
  "post/open.md":   { "owner": "bob", "write": ["bob", "@editors"] },
  "sec":            { "read": ["alice"] },
  "sec/owned.md":   { "owner": "bob", "write": ["bob"] },
  "drafts":         { "draft": true },
  "drafts/owned.md":{ "owner": "bob", "write": ["bob"] },
  "mixed":          { "read": ["alice"], "write": ["alice"] }
}
JSON

delete @ENV{qw(HTTP_X_REMOTE_USER HTTP_X_REMOTE_GROUPS LAZYSITE_AUTH_TRUSTED)};
load_processor($docroot);
no warnings 'once';
sub abs_of { return "$docroot/$page{ $_[0] }" }

my %expect = (    # governed, governing key
    open_post  => [ 0, undef ],
    plain      => [ 0, undef ],
    partial    => [ 0, undef ],
    read_sec   => [ 1, 'sec' ],
    read_owned => [ 1, 'sec' ],
    draft      => [ 1, 'drafts' ],
    draft_own  => [ 1, 'drafts' ],
    mixed      => [ 1, 'mixed' ],
);

for my $k ( sort keys %expect ) {
    my ( $gov, $key ) = @{ $expect{$k} };
    is( main::_acl_governed( abs_of($k) ), $gov, "$k: governed = $gov" );
    is( main::_acl_governing_key( abs_of($k) ), $key, "$k: governing key " . ( $key // 'none' ) );
    is( main::_registry_hidden( abs_of($k) ), $gov, "$k: " . ( $gov ? 'out of' : 'in' ) . ' the registries' );
    is( main::_scan_hidden( abs_of($k) ), $gov, "$k: " . ( $gov ? 'out of' : 'in' ) . ' an anonymous scan' );
}

subtest 'the registry walk lists write-only pages and nothing gated' => sub {
    my %listed = map { $_->{url} => 1 } main::scan_pages($docroot);
    ok( $listed{'/post/open'}, 'a post under its own write rule is listed' );
    ok( $listed{'/plain'},     'a page under the / write rule is listed' );
    ok( !$listed{$_}, "$_ is not listed" ) for qw(/sec/page /sec/owned /drafts/page /drafts/owned /mixed/page);
};

subtest 'an anonymous scan: list lists write-only pages and nothing gated' => sub {
    my %found = map { $_->{url} => 1 } @{ main::resolve_scan('/*/*.md') };
    ok( $found{'/post/open'}, 'the write-only post is found' );
    ok( !$found{$_}, "$_ is not found" ) for qw(/sec/page /sec/owned /drafts/page /drafts/owned /mixed/page);
};

done_testing();
