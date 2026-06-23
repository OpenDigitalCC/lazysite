#!/usr/bin/perl
# SM073 + list-by-type: action=list surfaces per-file metadata - the
# extension, generated-html detection (an .html with a .md/.url source
# beside it), and brief presence - that the Files page uses to filter
# by type and to flag files missing an authoring brief.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(repo_root);

sub spit { my ( $p, $c ) = @_; open my $f, '>', $p or die "$p: $!"; print $f $c; close $f }

my $root    = repo_root();
my $docroot = tempdir( CLEANUP => 1 );
make_path("$docroot/lazysite");
make_path("$docroot/partials");
spit( "$docroot/lazysite/lazysite.conf", "site_name: Test\n" );

# index.md + its generated cache index.html (a source sits beside it)
spit( "$docroot/index.md",   "---\ntitle: Home\n---\nHome.\n" );
spit( "$docroot/index.html", "<html>cached</html>" );
# about.md WITH a brief sidecar; contact.md WITHOUT one
spit( "$docroot/about.md",       "---\ntitle: About\n---\nAbout.\n" );
spit( "$docroot/about.md.brief", "intent: the about page\n" );
spit( "$docroot/contact.md",     "---\ntitle: Contact\n---\nContact.\n" );
# an author partial: note.html with NO source -> not "generated"
spit( "$docroot/partials/note.html", "<p>partial</p>" );

$ENV{LAZYSITE_API_LOAD_ONLY} = 1;
local $ENV{DOCUMENT_ROOT} = $docroot;
do "$root/lazysite-manager-api.pl" or die "load failed: $@";

my $r = main::action_list('/');
ok( $r->{ok}, 'list ok' );
my %by = map { $_->{name} => $_ } @{ $r->{entries} };

is( $by{'about.md'}{ext}, 'md', 'file extension surfaced' );
ok(  $by{'about.md'}{has_brief},      'about.md flagged as having a brief' );
ok( !$by{'contact.md'}{has_brief},    'contact.md flagged as missing a brief' );
ok(  $by{'about.md.brief'}{is_brief}, '.brief file flagged as a brief sidecar' );
ok( !exists $by{'about.md.brief'}{has_brief},
    'a brief carries no has_brief of its own' );
ok(  $by{'index.html'}{generated},
    'index.html (with an index.md source) is a generated cache file' );

# A partial in a subdir: list it, confirm an author .html is NOT "generated".
my $r2 = main::action_list('/partials');
my %by2 = map { $_->{name} => $_ } @{ $r2->{entries} };
ok( !$by2{'note.html'}{generated},
    'author .html with no source is not flagged generated' );

done_testing();
