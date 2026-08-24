#!/usr/bin/perl
# SM512: every drop and every lossy rebuild writes a safety export under
# lazysite/db/rebuilds/ - and nothing listed them or removed one, so each
# was permanent until an operator's filesystem trip. Five accumulated on
# edge in one day of field testing. The SM508 pattern, for tables: an
# agent authorised to drop was not authorised to tidy.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../../../lib";
use Lazysite::Manager::Data
    qw(action_data_safety_exports action_data_safety_export_delete);

my $docroot = tempdir( CLEANUP => 1 );
make_path("$docroot/lazysite/db/rebuilds");
open my $cf, '>', "$docroot/lazysite/lazysite.conf" or die $!;
print {$cf} "site_name: T\nplugins:\n  - plugins/data.pl\n";
close $cf;
$Lazysite::Manager::Data::DOCROOT = $docroot;
for my $f (qw(zz-dropped-20260824T133544Z.json things-20260824T140000Z.json notes.txt)) {
    open my $fh, '>', "$docroot/lazysite/db/rebuilds/$f" or die $!;
    print {$fh} "{}\n";
    close $fh;
}

subtest 'the exports can be listed, and say what they are' => sub {
    my $r = action_data_safety_exports();
    ok( $r->{ok}, 'listed' ) or diag explain $r;
    my %by = map { $_->{file} => $_ } @{ $r->{exports} };
    is( scalar keys %by, 2, 'only export-shaped files are exports' );
    is( $by{'zz-dropped-20260824T133544Z.json'}{kind},  'dropped', 'a drop export' );
    is( $by{'zz-dropped-20260824T133544Z.json'}{table}, 'zz',      'names its table' );
    is( $by{'things-20260824T140000Z.json'}{kind},      'rebuild', 'a rebuild export' );
    is( $r->{dir}, 'lazysite/db/rebuilds', 'and the reply says where, site-relative' );
};

subtest 'an export can be cleared, by its exact name' => sub {
    my $d = action_data_safety_export_delete('zz-dropped-20260824T133544Z.json');
    ok( $d->{ok}, 'deleted' ) or diag explain $d;
    ok( !-e "$docroot/lazysite/db/rebuilds/zz-dropped-20260824T133544Z.json", 'gone' );
    my $again = action_data_safety_export_delete('zz-dropped-20260824T133544Z.json');
    is( $again->{kind} // '', 'not-found', 'a second delete is an honest not-found' );
};

subtest 'SECURITY: only the minted shape reaches the unlink' => sub {
    for my $bad ( '../lazysite.conf', 'notes.txt', 'things-20260824T140000Z.json/../x',
        '/etc/passwd', 'things-2026.json' ) {
        my $d = action_data_safety_export_delete($bad);
        ok( !$d->{ok}, "refused: $bad" );
        is( $d->{kind} // '', 'name', 'by name, before any filesystem look' );
    }
    ok( -f "$docroot/lazysite/db/rebuilds/notes.txt", 'the stray file is untouched' );
    my $none = action_data_safety_export_delete('');
    ok( !$none->{ok}, 'an empty name is refused' );
};

done_testing();
