#!/usr/bin/perl
# SM1357: STRUCTURED DATA FOR SEARCH - schema.org JSON-LD on the pages a table's
# mapping names, from the rows an anonymous visitor may read now.
#
# Through the real render path:
#
#   * the pages the mapping names carry one JSON-LD block, and no other page does;
#   * only the rows available now: a row outside its shows_ window is not in it,
#     and a table that is not public contributes nothing - JSON-LD publishes what
#     the site already serves publicly, and nothing protected leaks;
#   * INERT: a row value spelling </script><script>... cannot close the element
#     or open markup - < > & are written as < > &, and the block
#     still reads back as the value;
#   * a row changed refreshes the page carrying it;
#   * the organisation entry on the home page, from the site's own details and
#     its schedule's hours - and none on a site that has stated no details;
#   * a mapping that is wrong is refused at the descriptor, by name.
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use JSON::PP   ();
use FindBin;
use lib "$FindBin::Bin/../../lib", "$FindBin::Bin/../../../lib";
use TestHelper qw(setup_test_site site_tempdir run_processor);

BEGIN {
    eval { require DBI; require DBD::SQLite; require YAML::PP; 1 }
        or plan skip_all => 'DBI/DBD::SQLite/YAML::PP not available';
}
use Lazysite::Data::Descriptor qw(load_descriptor);
use Lazysite::Data::Tables     qw(apply_schema insert_row);

sub spit { my ( $p, $t ) = @_; open my $fh, '>', $p or die "$p: $!"; print {$fh} $t; close $fh; return }

sub ld {
    my ($out) = @_;
    my @blocks = $out =~ m{<script type="application/ld\+json">(.*?)</script>}gs;
    return ( scalar @blocks, ( @blocks ? JSON::PP->new->decode( $blocks[0] ) : undef ), $blocks[0] // '' );
}

sub site {
    my (%o) = @_;
    my $docroot = site_tempdir();
    setup_test_site($docroot);
    make_path("$docroot/lazysite/db/tables");
    open my $cf, '>>', "$docroot/lazysite/lazysite.conf" or die $!;
    print {$cf} "time_zone: Europe/London\n";
    print {$cf} $o{conf} if $o{conf};
    print {$cf} "extensions:\n  - extensions/data.pl\n";
    close $cf;
    return $docroot;
}

my $EVENTS = <<'Y';
title: Events
public: true
fields:
  title:
    type: text
  starts:
    type: date
  venue:
    type: text
  link:
    type: text
  shows_until:
    type: date
structured_data:
  type: Event
  pages: [/events]
  properties:
    name: title
    startDate: starts
    url: link
    eventStatus: "=https://schema.org/EventScheduled"
    location:
      type: Place
      properties:
        name: venue
Y

my $PRIVATE = <<'Y';
title: Private
fields:
  title:
    type: text
structured_data:
  type: Event
  pages: [/events]
  properties:
    name: title
Y

my $d = site();
spit( "$d/lazysite/db/tables/events.yaml",  $EVENTS );
spit( "$d/lazysite/db/tables/private.yaml", $PRIVATE );
apply_schema( $d, $_ ) for qw(events private);
insert_row( $d, 'events', { title => 'Quiz night', starts => '2099-02-01', venue => 'The Hall', link => 'https://example.org/quiz' } );
insert_row( $d, 'events', { title => '</script><script>alert(1)</script>', starts => '2099-03-01', link => 'javascript:alert(2)' } );
insert_row( $d, 'events', { title => 'OVER', starts => '2001-01-01', shows_until => '2001-01-02' } );
insert_row( $d, 'private', { title => 'SECRET-EVENT' } );
spit( "$d/events.md", "---\ntitle: Events\n---\nEVENTS\n" );
spit( "$d/about.md",  "---\ntitle: About\n---\nABOUT\n" );

subtest 'the pages the mapping names, from the rows available now' => sub {
    my $out = run_processor( $d, '/events' );
    my ( $n, $doc, $raw ) = ld($out);
    is( $n, 1, 'the page carries one JSON-LD block' );
    ok( $doc && $doc->{'@context'} eq 'https://schema.org', 'a schema.org document' );
    my @g = @{ $doc->{'@graph'} || [] };
    is( scalar @g, 2, 'one object per row shown' );
    my ($quiz) = grep { $_->{name} eq 'Quiz night' } @g;
    is_deeply( $quiz, { '@type' => 'Event', name => 'Quiz night', startDate => '2099-02-01',
            url => 'https://example.org/quiz', eventStatus => 'https://schema.org/EventScheduled',
            location => { '@type' => 'Place', name => 'The Hall' } }, 'built as mapped, nested object and literal included' );
    ok( !grep( { $_->{name} eq 'OVER' } @g ), 'a row past its shows_until is not in it' );
    unlike( $raw, qr/SECRET-EVENT/, 'and a table that is not public contributes nothing' );
    unlike( $out, qr/SECRET-EVENT/, 'anywhere on the page' );

    unlike( run_processor( $d, '/about' ), qr{application/ld\+json}, 'a page the mapping does not name carries none' );
};

subtest 'inert: a row value cannot leave the script element' => sub {
    my $out = run_processor( $d, '/events' );
    my ( undef, $doc, $raw ) = ld($out);
    unlike( $out, qr{<script>alert}, 'no script element opens from a row' );
    unlike( $raw, qr{[<>&]}, 'no < > or & inside the block at all' );
    like( $raw, qr{\\u003c/script\\u003e\\u003cscript\\u003e}, 'they are written as \\u escapes' );
    my ($x) = grep { $_->{name} =~ /alert\(1\)/ } @{ $doc->{'@graph'} };
    is( $x->{name}, '</script><script>alert(1)</script>', 'and the value reads back exactly' );
    ok( !exists $x->{url}, 'a javascript: link is not published' );
};

subtest 'a row changed refreshes the page carrying it' => sub {
    run_processor( $d, '/events' );
    my $t = time - 30;
    utime( $t - 60, $t - 60, "$d/lazysite/lazysite.conf", glob("$d/*.md"), glob("$d/lazysite/db/stamps/*"),
        glob("$d/lazysite/db/tables/*") );
    utime( $t, $t, "$d/events.html" );
    insert_row( $d, 'events', { title => 'Late addition', starts => '2099-04-01' } );
    my ( undef, $doc ) = ld( run_processor( $d, '/events' ) );
    ok( grep( { $_->{name} eq 'Late addition' } @{ $doc->{'@graph'} } ), 'the new row is in the JSON-LD at once' );
};

subtest 'the organisation entry, from the site\'s own details' => sub {
    my $s = site( conf => "site_type: Restaurant\nsite_address: 1 High Street, Town\nsite_phone: 01234 567890\nsite_hours: opening\n" );
    spit( "$s/lazysite/db/tables/opening.yaml", "title: Opening hours\nschedule: true\npublic: true\n" );
    apply_schema( $s, 'opening' );
    insert_row( $s, 'opening', { kind => 'period', day => 'mon', opens => '09:00', closes => '17:00' } );
    my ( $n, $doc ) = ld( run_processor( $s, '/' ) );
    is( $n, 1, 'the home page carries it' );
    is( $doc->{'@type'}, 'Restaurant', 'as the type the site states' );
    is( $doc->{name},      'Test',                  'named as the site' );
    is( $doc->{url},       'http://localhost',      'at its address' );
    is( $doc->{address},   '1 High Street, Town',   'with its address' );
    is( $doc->{telephone}, '01234 567890',          'and telephone' );
    is_deeply( $doc->{openingHoursSpecification},
        [ { '@type' => 'OpeningHoursSpecification', dayOfWeek => 'https://schema.org/Monday', opens => '09:00', closes => '17:00' } ],
        'and its opening hours from the schedule' );
    my ( $none ) = ld( run_processor( $s, '/about-missing' ) );
    ok( !$none, 'not on any other page' );

    my $plain = site();
    my ($pn) = ld( run_processor( $plain, '/' ) );
    is( $pn, 0, 'a site that has stated nothing about itself publishes nothing new' );
};

subtest 'a wrong mapping is refused at the descriptor, by name' => sub {
    my %f = ( fields => { title => { type => 'text' } } );
    my $r = load_descriptor( 't', { %f, structured_data => { type => 'event', pages => ['/x'], properties => { name => 'title' } } } );
    like( $r->{error} // '', qr/'event' is not a schema.org type name/, 'a type that is not a schema.org name' );
    $r = load_descriptor( 't', { %f, structured_data => { type => 'Event', pages => ['/x'], properties => { name => 'nope' } } } );
    like( $r->{error} // '', qr/'name' names 'nope', which is not a field/, 'a property naming no field' );
    $r = load_descriptor( 't', { %f, structured_data => { type => 'Event', properties => { name => 'title' } } } );
    like( $r->{error} // '', qr/pages must name at least one page/, 'no pages' );
    $r = load_descriptor( 't', { %f, structured_data => { type => 'Event', pages => ['/../x'], properties => {} } } );
    like( $r->{error} // '', qr/is not a site path/, 'a page that is not a site path' );
    $r = load_descriptor( 't', { schedule => 'true', structured_data => { type => 'Store', pages => ['/'], properties => { name => 'note' } } } );
    like( $r->{error} // '', qr/a schedule's properties are literals/, 'a schedule mapped from a field' );
    $r = load_descriptor( 't', { %f, structured_data => { type => 'Event', pages => ['/events/'], properties => { name => 'title' } } } );
    is_deeply( $r->{structured_data}{pages}, ['/events'], 'a page written with a trailing slash is the page' );
};

done_testing();
