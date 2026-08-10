#!/usr/bin/perl
# SM268: regression tests for the ACL findings of the August 2026 review.
#
# Five highs, every one reproduced by the reviewer before it was fixed:
#
#   H10  an owner-only entry inside a gated folder republished the file - and
#        Duplicate in the file manager writes exactly that entry, so an ordinary
#        edit turned the gate off with no warning and no log line.
#   H11  a .url page inside a gated section was served with no ACL check at all,
#        because the gate sat inside `if (@md_stat)`.
#   H12  an unreadable or malformed acls.json failed OPEN, silently.
#   H14  the section's own landing page (`private.md` at /private) was not
#        covered by the folder key, so the front door of a held-back section
#        stayed open.
#   H3   folder scope existed only in the processor's copy, so the manager, MCP
#        and WebDAV granted read AND WRITE inside a "protected section".
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use File::Temp qw(tempdir);
use JSON::PP   qw(encode_json);
use FindBin;
use lib "$FindBin::Bin/../lib";
use lib "$FindBin::Bin/../../lib";
use TestHelper          qw(run_processor);
use Lazysite::Auth::Acl ();

sub spit { open my $fh, '>', $_[0] or die $!; print {$fh} $_[1]; close $fh }

my $docroot = tempdir( CLEANUP => 1 );
make_path( "$docroot/lazysite/auth", "$docroot/private" );
spit( "$docroot/lazysite/lazysite.conf", "site_name: T\n" );
spit( "$docroot/index.md",               "---\ntitle: Home\n---\nHome.\n" );
spit( "$docroot/private.md",             "---\ntitle: Section\n---\nLANDING-BODY\n" );
spit( "$docroot/private/secret.md",      "---\ntitle: S\n---\nSECRET-BODY\n" );
spit( "$docroot/private/notes.pdf",      "PDFBYTES" );
spit( "$docroot/private/remote.url",     "https://example.com/\n" );
spit( "$docroot/private/remote.html",    "REMOTE-CACHED-SECRET\n" );

sub write_acls {
    my ($text) = @_;    # raw, so a malformed store can be written deliberately
    spit( "$docroot/lazysite/auth/acls.json", $text );
    return;
}

sub clear {
    for my $f (qw(private.html private/secret.html index.html)) {
        unlink "$docroot/$f" if -f "$docroot/$f";
    }
    return;
}

sub get {
    my ($uri) = @_;
    clear();
    return run_processor( $docroot, $uri );
}

my $GATE = encode_json( { private => { read => ['alice'] } } );

# --- H10 -------------------------------------------------------------------
subtest 'an owner-only entry cannot republish a file inside a gated folder' => sub {
    write_acls(
        encode_json(
            { private => { read => ['alice'] },
                'private/secret.md' => { owner => 'alice' },
                'private/notes.pdf' => { owner => 'alice' },
            }
        )
    );

    my $page = get('/private/secret');
    unlike( $page, qr/SECRET-BODY/,
        'the page is still gated - an owner-only entry is not a tighter rule, '
            . 'it is no rule, and it must not win the longest match' );

    my $pdf = get('/private/notes.pdf');
    unlike( $pdf, qr/PDFBYTES/, 'and so is the asset' );
};

# --- H14 -------------------------------------------------------------------
subtest "a folder entry covers the section's own landing page" => sub {
    write_acls($GATE);
    my $out = get('/private');
    unlike( $out, qr/LANDING-BODY/,
        'the page that introduces a held-back section is the last one that '
            . 'should be public' );
};

# --- H11 -------------------------------------------------------------------
subtest 'a .url page inside a gated section is gated too' => sub {
    write_acls($GATE);
    my $out = get('/private/remote');
    unlike( $out, qr/REMOTE-CACHED-SECRET/,
        'the .url page and its render cache are both covered - the gate now '
            . 'runs for the resolved target, not only when a .md exists' );
};

# --- H12 -------------------------------------------------------------------
subtest 'an unparseable ACL store fails CLOSED' => sub {
    write_acls('{ "private": { "read": ["alice"] },,, }');    # deliberate garbage
    my $out = get('/private/secret');
    unlike( $out, qr/SECRET-BODY/,
        'refused - failing open here published every protected file with no '
            . 'WARN and no log flag, and hand-written JSON is the only '
            . 'interface for a folder rule' );
};

# --- H3 --------------------------------------------------------------------
# The shared implementation, which the manager, MCP and WebDAV use. Folder scope
# lived only in the processor's copy, so a "protected section" was protected on
# the anonymous path and nowhere else.
subtest 'the shared Auth::Acl honours folder scope for read AND write' => sub {
    local $Lazysite::Auth::Acl::DOCROOT     = $docroot;
    local @Lazysite::Auth::Acl::user_groups = ();
    write_acls( encode_json( { private => { read => ['alice'], write => ['alice'] } } ) );

    ok( !Lazysite::Auth::Acl::_acl_allows( 'private/secret.md', 'read', 'bob' ),
        'bob cannot READ inside the section through the authoring channels' );
    ok( !Lazysite::Auth::Acl::_acl_allows( 'private/secret.md', 'write', 'bob' ),
        'nor WRITE - which is the half that made a gated section editable' );
    ok( Lazysite::Auth::Acl::_acl_allows( 'private/secret.md', 'read', 'alice' ),
        'while the named user still can' );

    # And the same owner-only trap must not reopen it here.
    write_acls(
        encode_json(
            { private => { read => ['alice'], write => ['alice'] },
                'private/secret.md' => { owner => 'carol' },
            }
        )
    );
    ok( !Lazysite::Auth::Acl::_acl_allows( 'private/secret.md', 'read', 'bob' ),
        'an owner-only descendant does not reopen it on this side either' );

    # Nothing outside the section is affected.
    ok( Lazysite::Auth::Acl::_acl_allows( 'index.md', 'read', 'bob' ),
        'a path outside the section is unaffected' );
};

done_testing();
