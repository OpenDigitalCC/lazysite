#!/usr/bin/perl
# A SUBMISSION WITH A NON-ASCII CHARACTER IS SHOWN, AND CAN BE ACTED ON.
#
# SM904 made sure a value is STORED as the visitor typed it. The read half was
# never checked, and it was wrong three ways, all in the submissions readers the
# manager table, the control API and MCP share:
#
#   1. HIDDEN. The store is opened with :utf8, so each line is a character string,
#      and decode_json wants UTF-8 bytes - it refused every row holding a
#      non-ASCII character as "malformed UTF-8", and the reader counted the row
#      malformed and left it out. A visitor called Herve-with-an-accent submitted,
#      and the table showed nothing.
#   2. NO ID. The row id hashed the character string; sha256_hex dies on a
#      character above U+00FF, so such a row could not be deleted or confirmed.
#   3. MANGLED ON CONFIRM. Confirming a quarantined row wrote encode_json's BYTES
#      through the :utf8 layer, encoding them twice.
#
# Found while building SM938 D5, whose single-submission view reads through the
# same code.
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use JSON::PP   ();
use FindBin;
use lib "$FindBin::Bin/../../lib", "$FindBin::Bin/../../../lib";
use TestHelper qw(site_tempdir);
use Lazysite::Manager::Plugins ();
use Lazysite::Handlers         ();

my $d     = site_tempdir();
my $store = "$d/lazysite/forms/submissions/contact.jsonl";
make_path("$d/lazysite/forms/submissions");
{ open my $c, '>', "$d/lazysite/lazysite.conf" or die; print {$c} "site_name: T\n"; close $c }
{ open my $c, '>', "$d/lazysite/forms/contact.conf" or die; print {$c} "targets: []\n"; close $c }
$Lazysite::Manager::Plugins::DOCROOT = $d;
$Lazysite::Handlers::DOCROOT         = $d;

my $J = JSON::PP->new->canonical;
sub write_store {
    open my $f, '>:utf8', $store or die $!;
    print {$f} $J->encode($_) . "\n" for @_;
    close $f;
}
sub read_store {
    open my $f, '<:utf8', $store or die $!;
    my @r = map { $J->decode($_) } grep { /\S/ } <$f>;
    close $f;
    return @r;
}
sub list { Lazysite::Manager::Plugins::action_form_submissions('lazysite/forms/submissions/contact.jsonl') }
sub by_name { my ($r) = @_; return { map { $_->{name} => $_ } @{ $r->{rows} } } }

write_store(
    { name => 'Ann',          message => 'plain' },
    { name => "Herv\x{e9}",   message => 'Latin-1 range' },
    { name => "Zo\x{eb} \x{263a}", message => "above U+00FF \x{2014} a dash" },
);

subtest 'every row is shown, the non-ASCII ones included' => sub {
    my $r = eval { list() };
    ok( $r && $r->{ok}, 'the store reads' ) or return diag( $@ || explain $r );
    is( $r->{malformed}, 0, 'nothing is counted malformed' )
        or diag( 'A row holding an accented letter was reported malformed and left '
            . 'out of the table - the reported defect.' );
    is( $r->{shown}, 3, 'all three rows are shown' );
    my $b = by_name($r);
    ok( $b->{"Herv\x{e9}"}, 'the Latin-1 name, as typed' );
    is( $b->{"Zo\x{eb} \x{263a}"}{message}, "above U+00FF \x{2014} a dash", 'and the wide characters, as typed' );
};

subtest 'every row has an id, and the id is the hash of the line on disk' => sub {
    my $r = list();
    my @ids = map { $_->{_id} } @{ $r->{rows} };
    is( scalar( grep { /\A[0-9a-f]{16}\z/ } @ids ), 3, 'three ids of the documented shape' );
    open my $f, '<:raw', $store or die;
    my @bytes = grep { /\S/ } <$f>;
    close $f;
    s/\s+\z// for @bytes;
    require Digest::SHA;
    is_deeply( [ sort @ids ], [ sort map { substr( Digest::SHA::sha256_hex($_), 0, 16 ) } @bytes ],
        'each is the hash of the stored bytes, whatever layer the reader used' );
};

subtest 'a row above U+00FF can be deleted by its id' => sub {
    my $id = by_name( list() )->{"Zo\x{eb} \x{263a}"}{_id};
    my $r  = eval { Lazysite::Manager::Plugins::action_form_submission_delete(
            'lazysite/forms/submissions/contact.jsonl', $id ) };
    ok( $r && $r->{ok}, 'deleted' ) or diag( $@ || explain $r );
    is( scalar( read_store() ), 2, 'and the store lost exactly that row' );
};

subtest 'confirming a quarantined non-ASCII row keeps the text as typed' => sub {
    write_store( { name => "Herv\x{e9}", message => "caf\x{e9} \x{263a}", _quarantined => JSON::PP::true, _spam_reason => 't' } );
    my $id = list()->{rows}[0]{_id};
    my $r  = eval { Lazysite::Manager::Plugins::action_form_submission_confirm(
            'lazysite/forms/submissions/contact.jsonl', $id ) };
    ok( $r && $r->{ok}, 'confirmed' ) or diag( $@ || explain $r );
    my ($row) = read_store();
    is( $row->{message}, "caf\x{e9} \x{263a}", 'the message is unchanged' )
        or diag( 'Bytes written through a :utf8 layer are encoded twice: caf\\x{c3}\\x{a9}.' );
    ok( !exists $row->{_quarantined}, 'and the flag is gone' );
};

done_testing();
