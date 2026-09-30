#!/usr/bin/perl
# SM918: the notice bell has ONE reader, and it keeps the four states apart.
#
# Two things are being pinned, and they are different in kind.
#
# THE PARITY is structural: Lazysite::Manager::Notices is what both
# lazysite-manager-api.pl and lazysite-mcp.pl call, so there is no second reader
# to drift. t/lint/23 pins the pairing by name; this pins the behaviour, because
# a pairing that names two functions returning different things is a map, not a
# guarantee.
#
# THE FOUR STATES are the repair the move carried. The old reader was
#
#     if ( open my $fh, '<', _notices_path() ) { ...push... }
#
# with no else, so a store that EXISTS and cannot be opened produced an empty
# list and unread => 0 - a quiet bell, indistinguishable from a site that has
# had nothing to say. t/lint/121 could not see it: its matcher requires `or` on
# the open line and an open used as an `if` condition has none (SM917 measures
# how many others are in that blind spot).
#
# Absent is a REAL answer here and must stay silent - a site that has never
# emitted a notice has no file, and warning about that would train a sysop to
# ignore the warning.
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use JSON::PP   qw(encode_json decode_json);
use FindBin;
use lib "$FindBin::Bin/../../../lib";
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(site_tempdir);

use Lazysite::Manager::Notices ();

# site_tempdir, not a bare tempdir: SM744's lint 118 counts the latter, because
# a docroot AT the temp root cannot tell a path bug from a path that happens to
# work - there is nothing above it to get wrong.
my $root = site_tempdir();
my $lz   = "$root/lazysite";
make_path("$lz/logs");
$Lazysite::Manager::Notices::DOCROOT = $root;

my $NOTICES = "$lz/logs/notices.jsonl";
my $SEEN    = "$lz/logs/notices-seen.json";

sub write_notices {
    open my $fh, '>', $NOTICES or die $!;
    print {$fh} encode_json($_) . "\n" for @_;
    close $fh;
}

# --- 1. absent store: a real empty, and silent -------------------------------

subtest 'a site that has never emitted a notice reports an empty bell' => sub {
    unlink $NOTICES, $SEEN;
    my $r = Lazysite::Manager::Notices::action_notices('sysop');
    ok( $r->{ok}, 'ok' );
    is_deeply( $r->{notices}, [], 'no notices' );
    is( $r->{unread},    0, 'nothing unread' );
    is( $r->{last_seen}, 0, 'never marked seen' );
    ok( !$r->{store_unreadable}, 'NOT reported as unreadable - absent is a real answer' );
};

# --- 2. a populated store, newest first, per-principal unread ----------------

subtest 'notices come back newest first, and unread is per principal' => sub {
    write_notices(
        { ts => 1000, type => 'form', message => 'oldest' },
        { ts => 2000, type => 'form', message => 'middle' },
        { ts => 3000, type => 'form', message => 'newest' },
    );
    open my $sf, '>', $SEEN or die $!;
    print {$sf} encode_json( { sysop => 2000 } );
    close $sf;

    my $r = Lazysite::Manager::Notices::action_notices('sysop');
    is( scalar @{ $r->{notices} }, 3, 'three notices' );
    is( $r->{notices}[0]{message}, 'newest', 'newest first' );
    is( $r->{last_seen},           2000,     'this principal\'s marker' );
    is( $r->{unread},              1,        'only the one after the marker' );

    # A DIFFERENT principal has its own position, and an unknown one has none.
    # This is the field that would quietly become wrong if the module read a
    # CGI global instead of its argument.
    my $other = Lazysite::Manager::Notices::action_notices('partner-bot');
    is( $other->{last_seen}, 0, 'a principal with no marker has not seen anything' );
    is( $other->{unread},    3, 'so everything is unread for it' );
};

# --- 3. the state the old reader could not express ---------------------------

SKIP: {
    skip 'running as root, which can open a 0000 file', 3 if $> == 0;

    subtest 'a store that exists and will not open is NOT an empty bell' => sub {
        write_notices( { ts => 1000, type => 'form', message => 'present but unreadable' } );
        chmod 0000, $NOTICES or die "chmod: $!";

        my $r = Lazysite::Manager::Notices::action_notices('sysop');
        ok( $r->{store_unreadable}, 'the cannot-tell state is reported, not inferred' );
        like( $r->{error}, qr/could not be read/i, 'and says so in words' );
        like( $r->{error}, qr/not an empty bell|not a fact/i,
            'naming the wrong conclusion it exists to prevent' );

        chmod 0644, $NOTICES;
    };

    subtest 'an unreadable seen-marker is not silently treated as position zero' => sub {
        write_notices( { ts => 1000, type => 'form', message => 'x' } );
        open my $sf, '>', $SEEN or die $!;
        print {$sf} encode_json( { sysop => 900 } );
        close $sf;
        chmod 0000, $SEEN or die "chmod: $!";

        my $r = Lazysite::Manager::Notices::action_notices('sysop');
        ok( $r->{seen_unreadable}, 'reported separately from the store' );
        ok( !$r->{store_unreadable}, 'the two reads fail independently' );

        chmod 0644, $SEEN;
    };

    # THE WRITE REFUSES rather than clobbering. Rewriting a marker file we could
    # not read would drop every other operator's position - a write that loses
    # other people's state because it could not see it.
    subtest 'marking seen refuses on an unreadable marker rather than rewriting it' => sub {
        open my $sf, '>', $SEEN or die $!;
        print {$sf} encode_json( { someone_else => 5000 } );
        close $sf;
        chmod 0000, $SEEN or die "chmod: $!";

        my $r = Lazysite::Manager::Notices::action_notices_seen('sysop');
        ok( !$r->{ok}, 'refused' );
        like( $r->{error}, qr/discard every other/i, 'and names what it would have cost' );

        chmod 0644, $SEEN;
        my $back = decode_json( do { open my $f, '<', $SEEN or die $!; local $/; <$f> } );
        is( $back->{someone_else}, 5000, 'the other operator\'s position survived' );
        ok( !exists $back->{sysop}, 'and nothing was written for the caller' );
    };
}

# --- 4. marking seen, on the happy path -------------------------------------

subtest 'marking seen records this principal and leaves the others alone' => sub {
    open my $sf, '>', $SEEN or die $!;
    print {$sf} encode_json( { someone_else => 5000 } );
    close $sf;

    my $r = Lazysite::Manager::Notices::action_notices_seen('sysop');
    ok( $r->{ok}, 'ok' );
    my $back = decode_json( do { open my $f, '<', $SEEN or die $!; local $/; <$f> } );
    ok( $back->{sysop} > 0,         'the caller has a position now' );
    is( $back->{someone_else}, 5000, 'and the other one is untouched' );
};

subtest 'marking seen needs a principal to mark it for' => sub {
    for my $p ( undef, '' ) {
        my $r = Lazysite::Manager::Notices::action_notices_seen($p);
        ok( !$r->{ok}, 'refused without a principal' );
        like( $r->{error}, qr/principal is required/i, 'named as missing' );
    }
};

# --- 5. the bound is the most recent 100 ------------------------------------

subtest 'the store is bounded to the most recent 100 notices' => sub {
    write_notices( map { { ts => $_, type => 'form', message => "n$_" } } 1 .. 150 );
    my $r = Lazysite::Manager::Notices::action_notices('nobody');
    is( scalar @{ $r->{notices} }, 100, '100 returned' );
    is( $r->{notices}[0]{message}, 'n150', 'and they are the NEWEST 100, newest first' );
    is( $r->{notices}[-1]{message}, 'n51', 'the oldest kept is n51' );
};

done_testing();
