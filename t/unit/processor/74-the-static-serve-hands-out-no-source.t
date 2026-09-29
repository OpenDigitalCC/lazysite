#!/usr/bin/perl
# SM797: the anonymous static serve does not hand out source.
#
# Security review, 0.13.8: _serve_content_static served raw bytes for any
# trailing-alphanumeric extension with no denylist, while DAV - the
# AUTHENTICATED surface - refused dangerous types. And sanitise_uri stripped a
# page extension ONCE, so `/<page>.md.md` resolved to `<page>.md`, which still
# had an extension and went down the static branch as source: a draft page's
# markdown, an api page's body, `.url.url` revealing an upstream.
#
# RULED 2026-09-09: the collapse in sanitise_uri is the fix, the denylist is the
# belt, and an allowlist was refused because it silently stops a site serving an
# unlisted type on upgrade. So this file asserts BOTH directions: what must not
# leave, and what must still leave.
#
# Driven through the real request path on a site with an ACL store, because that
# is when the engine serves statics at all - on a site without one, the front
# end hands them over directly and this branch never runs.
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(setup_minimal_site site_tempdir run_processor load_processor);

my $d = site_tempdir();    # lint 118: not a bare tempdir
setup_minimal_site($d);

# An ACL store switches the static branch on, which is the exposed case.
make_path("$d/lazysite/auth");
open my $af, '>', "$d/lazysite/auth/acls.json" or die $!;
print {$af} "{}\n";
close $af;

sub put {
    my ( $rel, $body ) = @_;
    open my $fh, '>', "$d/$rel" or die "$rel: $!";
    print {$fh} $body;
    close $fh;
}

put( 'draft.md',    "---\ntitle: Draft\ndraft: true\n---\n\nSECRET-DRAFT-BODY\n" );
put( 'config.bak',  "BACKUP-SECRET\n" );
put( 'upstream.url', "https://internal.example/SECRET-UPSTREAM\n" );
put( 'notes.swp',   "SWAP-SECRET\n" );
put( 'script.pl',   "#!/usr/bin/perl\n# PERL-SECRET\n" );
put( 'site.env',    "API_KEY=ENV-SECRET\n" );
# and the things a site legitimately serves as raw bytes
put( 'data.json',   "{\"public\":\"JSON-PUBLIC\"}\n" );
put( 'robots.txt',  "User-agent: *\nROBOTS-PUBLIC\n" );

sub fetch { return run_processor( $d, $_[0] ) // '' }

# --- THE CANARY -------------------------------------------------------------
# A "the secret is absent" check passes against an engine that serves nothing,
# so the rig must first be seen serving a static at all.
like( fetch('/robots.txt'), qr/ROBOTS-PUBLIC/,
    'a legitimate static is served - the rig can see a static at all' );

# --- THE FIX: the collapse --------------------------------------------------
# THE PROPERTY IS EQUIVALENCE, not absence of the page's words. A doubled
# extension must get exactly what the plain URL gets - the rendered page, under
# whatever draft and access rules apply to it - and never the source file. An
# earlier draft of this test asserted the body text was absent, which failed on
# a correct engine: that page renders its body for anyone, and the disclosure was
# never the words but the MARKDOWN - front matter and all - as raw bytes.
sub split_response {
    my ($out) = @_;
    my ($st) = $out =~ /^Status: ([^\n]*)/m;
    my ($ct) = $out =~ /^Content-type: ([^\n]*)/mi;
    my ($body) = $out =~ /\r?\n\r?\n(.*)\z/s;
    return ( $st // '', $ct // '', $body // '' );
}

for my $pair ( [ '/draft.md.md', '/draft' ], [ '/upstream.url.url', '/upstream' ] ) {
    my ( $doubled, $plain ) = @$pair;
    my @d = split_response( fetch($doubled) );
    my @p = split_response( fetch($plain) );
    is( $d[1], $p[1], "$doubled answers with the same content type as $plain" );
    like( $d[1], qr{\Atext/html}, "...which is the rendered page, not raw bytes" );
    unlike( $d[2], qr/^---\s*\n\s*title:/m, "$doubled does not return front matter" );
}

# THE SINGLE EXTENSION: CHANGED DELIBERATELY BY SM825, 2026-09-29.
#
# This asserted that `/draft.md` returns no front matter, on the grounds that it
# renders rather than serving source. SM825 gives a page a SOURCE ALTERNATE at
# that URL - `llms.txt` has linked to it since SM299 and was getting HTML - so it
# now answers with markdown, and with an ALLOWLIST of three front-matter keys
# (title, subtitle, description) built rather than filtered.
#
# What SM797 established is untouched, and the two assertions below are the parts
# of this one that were load-bearing:
#
#   - the DOUBLED extension still renders, tested in the loop above. That was the
#     actual defect: `/draft.md.md` resolved to `draft.md`, still had an
#     extension, and went down the static branch as raw bytes.
#   - the alternate publishes no CONFIGURATION. `draft: true` in this fixture's
#     front matter is decoration, not a gate - `_acl_is_draft` reads an
#     acls.json entry, so this page was never a draft and its prose was already
#     public through the rendering. A real draft is refused before the emitter
#     runs; t/unit/processor/81 proves that with a store entry.
{
    my $md = ( split_response( fetch('/draft.md') ) )[2];
    like( $md, qr/^title:/m, 'a single page extension now serves the source alternate' );
    unlike( $md, qr/^draft:/m,
        'and the alternate publishes no configuration key, only the allowlisted three' )
        or diag( 'SM825 built its front matter from an allowlist precisely so that '
            . 'no key here leaks; a filter would have let draft: through.' );
}

# --- THE BELT: the denylist -------------------------------------------------
for my $case (
    [ '/config.bak', 'BACKUP-SECRET', 'a backup file' ],
    [ '/notes.swp',  'SWAP-SECRET',   'an editor swap file' ],
    [ '/script.pl',  'PERL-SECRET',   'executable source' ],
    [ '/site.env',   'ENV-SECRET',    'an env file' ],
    )
{
    my ( $url, $secret, $what ) = @$case;
    unlike( fetch($url), qr/\Q$secret\E/, "$what is not handed out ($url)" );
}

# --- AND WHAT MUST STILL LEAVE ----------------------------------------------
# The ruling refused an allowlist because it stops a site serving a type nobody
# listed. JSON is the case that proves the list is not one in disguise.
like( fetch('/data.json'), qr/JSON-PUBLIC/,
    'JSON is still served - sites publish data and manifests on purpose' );

# --- EACH HALF PINNED ON ITS OWN --------------------------------------------
# The two halves overlap on purpose: with the collapse reverted, the denylist
# still refuses `.md`, so every request above still passes. That is defence in
# depth working - and it means the requests above cannot tell whether the
# collapse is there. So the mechanism the ruling called THE fix is asserted
# directly, where nothing else can stand in for it.
load_processor($d);
is( main::sanitise_uri('/draft.md.md'),     'draft',    'a doubled page extension collapses to the page' );
is( main::sanitise_uri('/upstream.url.url'), 'upstream', '...for .url as well' );
is( main::sanitise_uri('/a.html.md.url'),    'a',        '...and for any run of page extensions' );
is( main::sanitise_uri('/draft.md'),         'draft',    'a single extension strips as it always did' );
is( main::sanitise_uri('/robots.txt'),       'robots.txt', 'a non-page extension is left alone' );

done_testing();
