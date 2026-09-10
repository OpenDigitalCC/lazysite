#!/usr/bin/perl
# SM822: the connector call record had no retention at all.
#
# 47 entries survived on edge from connectors deleted days earlier, and every test
# run added more. The field's reading was that this "is probably right for an
# audit", which is the crux: a record whose rows vanish when their connector is
# deleted is a record an operator can erase by deleting the thing it describes,
# and SM771 established that every refusal is a row.
#
# So it prunes by AGE and never on delete. A deleted connector's calls outlive it
# and expire on their own schedule - the audit property kept, the store bounded.
#
# The engine already SAID it did this: a comment above `due_scheduled` describes
# the scheduler job as expiring "the record past its keep". Nothing implemented
# it, and nothing anywhere else touched calls.jsonl - a declaration the code
# ignored, which is why the field found 47 rows and no policy.
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use JSON::PP;
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(site_tempdir);

require Lazysite::Manager::Connectors;

my $docroot = site_tempdir();
make_path("$docroot/lazysite/connectors");
{
    no warnings 'once';
    $Lazysite::Manager::Connectors::DOCROOT = $docroot;
}
my $calls = "$docroot/lazysite/connectors/calls.jsonl";
my $conf  = "$docroot/lazysite/lazysite.conf";

sub write_calls {
    my (@recs) = @_;
    open my $fh, '>:raw', $calls or die $!;
    print {$fh} JSON::PP->new->canonical->encode($_), "\n" for @recs;
    close $fh;
}

sub read_calls {
    open my $fh, '<:raw', $calls or return ();
    my @r;
    while ( my $l = <$fh> ) { push @r, eval { JSON::PP::decode_json($l) } }
    close $fh;
    return grep { ref $_ eq 'HASH' } @r;
}

my $day = 86400;

# --- inside the window: nothing is touched ----------------------------------
{
    write_calls(
        { call_id => 'a', connector => 'x', at => time - 3 * $day, state => 'answered' },
        { call_id => 'b', connector => 'x', at => time - 1 * $day, state => 'refused' },
    );
    Lazysite::Manager::Connectors::_prune_calls();
    my @r = read_calls();
    is( scalar @r, 2, 'recent calls are left alone' );
}

# --- past the window: the old ones go, the recent ones stay -----------------
{
    write_calls(
        { call_id => 'old1', connector => 'gone', at => time - 200 * $day, state => 'answered' },
        { call_id => 'old2', connector => 'gone', at => time - 120 * $day, state => 'refused' },
        { call_id => 'new1', connector => 'x',    at => time - 2 * $day,   state => 'answered' },
    );
    Lazysite::Manager::Connectors::_prune_calls();
    my @r = read_calls();
    is( scalar @r, 1, 'entries past the default 90-day window are dropped' );
    is( $r[0]{call_id}, 'new1', 'and the recent one is the survivor' );
}

# --- A DELETED CONNECTOR'S CALLS SURVIVE IT ---------------------------------
# This is the property the field asked to be deliberate about: pruning on delete
# would make the record erasable by the act it exists to record.
{
    write_calls(
        { call_id => 'd1', connector => 'deleted-days-ago', at => time - 5 * $day, state => 'refused' },
    );
    Lazysite::Manager::Connectors::_prune_calls();
    my @r = read_calls();
    is( scalar @r, 1, "a deleted connector's calls are still there" );
}

# --- the window is configurable ---------------------------------------------
{
    open my $c, '>', $conf or die $!;
    print $c "site_name: T\nconnector_call_retention_days: 7\n";
    close $c;
    is( Lazysite::Manager::Connectors::_retention_days(), 7, 'the conf sets the window' );

    write_calls(
        { call_id => 'w1', connector => 'x', at => time - 30 * $day, state => 'answered' },
        { call_id => 'w2', connector => 'x', at => time - 2 * $day,  state => 'answered' },
    );
    Lazysite::Manager::Connectors::_prune_calls();
    my @r = read_calls();
    is( scalar @r, 1, 'a shorter window prunes more' );
    is( $r[0]{call_id}, 'w2', 'keeping what is inside it' );
}

# --- a nonsense window falls back rather than keeping nothing ----------------
{
    open my $c, '>', $conf or die $!;
    print $c "connector_call_retention_days: 0\n";
    close $c;
    is( Lazysite::Manager::Connectors::_retention_days(), 90,
        'zero is refused - it would mean prune everything on every write' );

    open my $c2, '>', $conf or die $!;
    print $c2 "connector_call_retention_days: banana\n";
    close $c2;
    is( Lazysite::Manager::Connectors::_retention_days(), 90,
        'and so is a non-number' );
}

# --- WHAT IT CANNOT DATE, IT WILL NOT DISCARD -------------------------------
# A line that will not parse, or carries no timestamp, is kept. Dropping it would
# delete a record because one byte of it is unreadable.
{
    open my $fh, '>:raw', $calls or die $!;
    print {$fh} JSON::PP->new->canonical->encode(
        { call_id => 'ancient', connector => 'x', at => time - 300 * $day } ), "\n";
    print {$fh} "{ this is not json\n";
    print {$fh} JSON::PP->new->canonical->encode( { call_id => 'undated', connector => 'x' } ), "\n";
    close $fh;

    open my $c, '>', $conf or die $!;
    print $c "site_name: T\n";
    close $c;

    Lazysite::Manager::Connectors::_prune_calls();
    open my $in, '<:raw', $calls or die $!;
    my $body = do { local $/; <$in> };
    close $in;
    like( $body, qr/this is not json/, 'an unparseable line is kept' );
    like( $body, qr/undated/,          'and a line with no timestamp is kept' );
    unlike( $body, qr/ancient/,        'while the one it could date is pruned' );
}

done_testing();
