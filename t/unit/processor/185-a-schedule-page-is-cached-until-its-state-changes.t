#!/usr/bin/perl
# SM1356 / SM1357: A PAGE SHOWING "NOW" IS CACHED ONLY UNTIL THE NEXT CHANGE OF
# STATE, AND A ROW CHANGED REFRESHES THE PAGES CARRYING IT.
#
# Through the real render path - the processor run as the CGI it is:
#
#   * `schedule:<table>` puts the schedule's state on the page (the label, the
#     week, the next exception), escaped as a db: value is;
#   * the render records its expiry (the next change of state, at most local
#     midnight) and the table's change stamp, and is cached - a schedule page
#     is not live;
#   * past the expiry the page renders again, on the plain cache branch AND on
#     the ttl: branch, which otherwise waits a page's ttl out: a stale "open
#     now" is never served;
#   * a row written through the data layer refreshes the page on both branches,
#     and a db: page with a ttl: too (the stamp) - "a change to a row refreshes
#     the pages carrying its data";
#   * the response's max-age never reaches past the expiry;
#   * a dated row's window is the page's expiry as well.
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use POSIX      ();
use FindBin;
use lib "$FindBin::Bin/../../lib", "$FindBin::Bin/../../../lib";
use TestHelper qw(setup_test_site site_tempdir run_processor);

BEGIN {
    eval { require DBI; require DBD::SQLite; require YAML::PP; 1 }
        or plan skip_all => 'DBI/DBD::SQLite/YAML::PP not available';
}
use Lazysite::Data::Schedule ();
use Lazysite::Data::Tables   qw(apply_schema insert_row);

plan skip_all => 'the host has no zoneinfo for Europe/London'
    unless Lazysite::Data::Schedule::valid_zone('Europe/London');

sub spit { my ( $p, $t ) = @_; open my $fh, '>', $p or die "$p: $!"; print {$fh} $t; close $fh; return }

sub slurp {
    my ($p) = @_;
    open my $fh, '<', $p or return '';
    local $/;
    my $t = <$fh>;
    close $fh;
    return $t;
}

# Today and tomorrow in London, and the epoch of the next London midnight.
my ( $today, $tomorrow_midnight ) = Lazysite::Data::Schedule::in_zone( 'Europe/London', sub {
    my @lt = localtime(time);
    my $t  = sprintf( '%04d-%02d-%02d', $lt[5] + 1900, $lt[4] + 1, $lt[3] );
    return ( $t, POSIX::mktime( 0, 0, 0, $lt[3] + 1, $lt[4], $lt[5], 0, 0, -1 ) );
} );

my $docroot = site_tempdir();
setup_test_site($docroot);
make_path("$docroot/lazysite/db/tables");
open my $cf, '>>', "$docroot/lazysite/lazysite.conf" or die $!;
print {$cf} "time_zone: Europe/London\nextensions:\n  - extensions/data.pl\n";
close $cf;

spit( "$docroot/lazysite/db/tables/opening.yaml", "title: Opening hours\nschedule: true\npublic: true\n" );
spit( "$docroot/lazysite/db/tables/offers.yaml",
    "title: Offers\npublic: true\nfields:\n  name:\n    type: text\n  shows_until:\n    type: date\n" );
apply_schema( $docroot, $_ ) for qw(opening offers);

# Open 09:00 to 17:00 every day, and closed today by an exception - so whatever
# the hour this runs, the page says the same thing until London's midnight.
insert_row( $docroot, 'opening', { kind => 'period', day => $_, opens => '09:00', closes => '17:00' } )
    for Lazysite::Data::Schedule::days();
insert_row( $docroot, 'opening',
    { kind => 'exception', date_from => $today, closed => 'true', note => '<script>alert(1)</script>' } );
insert_row( $docroot, 'offers', { name => 'OFFER-A', shows_until => '2099-12-31' } );

my $HOURS = "[% hours.label %]|[% hours.next_exception.note %]|"
    . "[% FOREACH d IN hours.week %][% d.name %]=[% d.periods.0.opens %]-[% d.periods.0.closes %];[% END %]";
spit( "$docroot/hours.md", "---\ntitle: Hours\ntt_page_var:\n  hours: schedule:opening\n---\n$HOURS\n" );
spit( "$docroot/hours-ttl.md", "---\ntitle: Hours\nttl: 86400\ntt_page_var:\n  hours: schedule:opening\n---\n$HOURS\n" );
spit( "$docroot/offers.md",
    "---\ntitle: Offers\nttl: 86400\ntt_page_var:\n  items: db:offers(order=name)\n---\n"
        . "[% FOREACH i IN items %]<li>[% i.name %]</li>[% END %]\n" );

my $deps = sub { slurp("$docroot/lazysite/cache/ct/$_[0].deps") };

# A sentinel written into the cached render: present in the response means it was
# served from the cache, absent means the page was rendered again.
sub mark {
    my ($base) = @_;
    my $p = "$docroot/$base.html";
    my $h = slurp($p);
    $h =~ s{<body>}{<body>CACHED-SENTINEL};
    spit( $p, $h );
    return;
}

# The render as if written $s seconds ago, and everything it was rendered from
# (the conf, the pages, the tables' stamps) a minute before that - so a write
# made now is newer than the render, and nothing else is.
sub age {
    my ( $base, $s ) = @_;
    my $t   = time - $s;
    my $old = $t - 60;
    utime( $old, $old, "$docroot/lazysite/lazysite.conf", glob("$docroot/*.md"),
        glob("$docroot/lazysite/db/stamps/*") );
    utime( $t, $t, "$docroot/$base.html" );
    return;
}

sub set_expiry {    # the record's expiry moved to $at
    my ( $base, $at ) = @_;
    my $p = "$docroot/lazysite/cache/ct/$base.deps";
    my $d = slurp($p);
    $d =~ s/^\@\d+$/\@$at/m or die "no expiry line in $p";
    spit( $p, $d );
    return;
}

subtest 'the page shows the schedule, escaped' => sub {
    my $out = run_processor( $docroot, '/hours' );
    like( $out, qr/Opens tomorrow at 09:00\|/, 'the label is what the schedule says now' );
    like( $out, qr/Monday=09:00-17:00;Tuesday=09:00-17:00;/, 'with the week' );
    unlike( $out, qr/<script>alert/, 'a row\'s text never reaches the page as markup' );
    like( $out, qr/&lt;script&gt;alert\(1\)&lt;\/script&gt;/, 'it is escaped, as a db: value is' );
};

subtest 'cached until the next change of state, and not past it' => sub {
    ok( -f "$docroot/hours.html", 'a schedule page is cached (it is not live)' );
    my $d = $deps->('hours');
    unlike( $d, qr/^!$/m, 'and its record does not mark it live' );
    like( $d, qr/^\@$tomorrow_midnight$/m, 'its expiry is London\'s next midnight, when "tomorrow" becomes "today"' );
    like( $d, qr{^=\Q$docroot\E/lazysite/db/stamps/opening$}m, 'and it records the schedule table\'s change stamp' );

    mark('hours');
    age( 'hours', 5 );
    like( run_processor( $docroot, '/hours' ), qr/CACHED-SENTINEL/, 'before the expiry it is served from the cache' );

    mark('hours');
    age( 'hours', 5 );
    set_expiry( 'hours', time - 1 );
    unlike( run_processor( $docroot, '/hours' ), qr/CACHED-SENTINEL/, 'past it, the page is rendered again' );
};

subtest 'a ttl: does not outlast the expiry' => sub {
    my $out = run_processor( $docroot, '/hours-ttl' );
    my ($max) = $out =~ /^Cache-Control: public, max-age=(\d+)/m;
    ok( defined $max, 'a ttl: page is publicly cacheable' );
    ok( $max <= $tomorrow_midnight - time + 1, "but for no longer than until the expiry ($max s, not 86400)" );

    mark('hours-ttl');
    age( 'hours-ttl', 5 );
    like( run_processor( $docroot, '/hours-ttl' ), qr/CACHED-SENTINEL/, 'inside its ttl and its expiry: the cache' );

    mark('hours-ttl');
    age( 'hours-ttl', 5 );
    set_expiry( 'hours-ttl', time - 1 );
    unlike( run_processor( $docroot, '/hours-ttl' ), qr/CACHED-SENTINEL/,
        'past the expiry, inside the ttl: rendered again - a stale "open now" is never served' );
};

subtest 'a row changed refreshes the page carrying it' => sub {
    run_processor( $docroot, '/hours' );
    run_processor( $docroot, '/hours-ttl' );
    mark($_)      for qw(hours hours-ttl);
    age( $_, 30 ) for qw(hours hours-ttl);
    insert_row( $docroot, 'opening', { kind => 'exception', date_from => '2099-01-01', closed => 'true', note => 'FAR' } );
    unlike( run_processor( $docroot, '/hours' ), qr/CACHED-SENTINEL/, 'the plain page renders again' );
    unlike( run_processor( $docroot, '/hours-ttl' ), qr/CACHED-SENTINEL/, 'and so does the ttl: page' );
};

subtest 'a db: page with a ttl: refreshes on a row write, and expires with its dated rows' => sub {
    my $out = run_processor( $docroot, '/offers' );
    like( $out, qr{<li>OFFER-A</li>}, 'the rows render' );
    my $d = $deps->('offers');
    like( $d, qr{^=\Q$docroot\E/lazysite/db/stamps/offers$}m, 'the db: binding records its table\'s stamp' );
    my $end = Lazysite::Data::Schedule::in_zone( 'Europe/London',
        sub { POSIX::mktime( 0, 0, 0, 1, 0, 2100 - 1900, 0, 0, -1 ) } );
    like( $d, qr/^\@$end$/m, 'and the dated row\'s window is its expiry (the midnight after shows_until)' );

    mark('offers');
    age( 'offers', 30 );
    like( run_processor( $docroot, '/offers' ), qr/CACHED-SENTINEL/, 'inside its ttl: the cache, as before' );
    insert_row( $docroot, 'offers', { name => 'OFFER-B' } );
    my $after = run_processor( $docroot, '/offers' );
    unlike( $after, qr/CACHED-SENTINEL/, 'a row written: rendered again, inside the ttl' );
    like( $after, qr{<li>OFFER-B</li>}, 'with the new row' );
};

done_testing();
