#!/usr/bin/perl
# SM223: the dev server must not serve an existing static file itself once the
# site has an ACL store.
#
# The whole filing is one structural mistake repeated: a front end answers from
# disk, the engine never sees the request, and no access rule the engine holds
# can apply. It was true of Apache's [L] rewrites, of nginx's try_files, and it
# was true HERE - the dev server's static handler runs before the processor, so
# adding the vhost rules alone would have left every dev/preview instance
# serving private files to anyone who knew the path.
#
# The predicate is driven directly, with no port, the way _dev_path_ok already
# is in 02-dev-server-confinement.t.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(repo_root);

my $server = repo_root() . '/tools/lazysite-server.pl';
require $server;
can_ok( 'main', '_dev_serve_direct' );

my $d = tempdir( CLEANUP => 1 );
make_path( "$d/lazysite/auth", "$d/private" );
for my $f (
    "$d/private/brief.html", "$d/private/notes.pdf",
    "$d/style.css",          "$d/page.md",
    "$d/rendered.html",      "$d/rendered.md",
    )
{
    open my $fh, '>', $f or die "$f: $!";
    print $fh "x\n";
    close $fh;
}

# --- no ACL store: the dev server serves statics itself, exactly as before ---
subtest 'without an ACL store nothing changes' => sub {
    ok( main::_dev_serve_direct( "$d/private/brief.html", $d ),
        'a source-less .html is served directly' );
    ok( main::_dev_serve_direct( "$d/private/notes.pdf", $d ),
        'and a PDF' );
    ok( main::_dev_serve_direct( "$d/style.css", $d ), 'and an asset' );
};

# --- the pre-existing reasons to decline are unchanged ----------------------
subtest 'source files and rendered pages still go to the processor' => sub {
    ok( !main::_dev_serve_direct( "$d/page.md", $d ),
        'a .md source is never served raw' );
    ok( !main::_dev_serve_direct( "$d/rendered.html", $d ),
        'a .html WITH a .md source belongs to the processor - serving the '
            . 'cached render here would skip it' );
    ok( !main::_dev_serve_direct( "$d/nope.html", $d ),
        'a file that does not exist is not served' );
};

# --- with an ACL store: hand everything to the engine -----------------------
subtest 'an ACL store sends statics to the engine' => sub {
    open my $a, '>', "$d/lazysite/auth/acls.json" or die $!;
    print {$a} '{"private":{"read":["alice"]}}';
    close $a;

    ok( !main::_dev_serve_direct( "$d/private/brief.html", $d ),
        'the .html now goes to the processor, which can consult the ACL' );
    ok( !main::_dev_serve_direct( "$d/private/notes.pdf", $d ),
        'and so does the PDF - the reported exposure was a PDF as much as an '
            . 'application' );

    # Deliberately ALL statics, not only the ones an entry names. The dev server
    # would otherwise have to parse acls.json on every request to decide, which
    # duplicates the decision the processor is about to make anyway - and a
    # front end that half-knows the ACL is how the two drift apart.
    ok( !main::_dev_serve_direct( "$d/style.css", $d ),
        'including files with no entry - the front end does not second-guess '
            . 'the ACL, it just stops answering' );
};

done_testing();
