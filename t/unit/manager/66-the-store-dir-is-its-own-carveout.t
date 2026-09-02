#!/usr/bin/perl
# SM509: the manager's submissions panel said "No submissions yet" for a
# store the API read five rows from - same site, same moment. The panel
# probes with `action=list` on the store DIRECTORY, and the carve-out's
# prefix test ('lazysite/forms/submissions/') matched only paths UNDER the
# store, never the directory itself. The refusal came back as a fetch
# error, and the panel's catch-all rendered it as an empty state - debris
# the operator could not see and therefore could not clear.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../../../lib";
use Lazysite::Manager::Common qw(is_blocked_path carveout_requirement);
use Lazysite::Manager::Files  qw(action_list);

my $docroot = tempdir( CLEANUP => 1 );
make_path("$docroot/lazysite/forms/submissions");
make_path("$docroot/lazysite/auth");
open my $sf, '>', "$docroot/lazysite/forms/submissions/contact.jsonl" or die $!;
print {$sf} qq({"_id":"a","name":"x"}\n);
close $sf;
$Lazysite::Manager::Common::DOCROOT = $docroot;
$Lazysite::Manager::Files::DOCROOT  = $docroot;

subtest 'the store directory is inside its own carve-out' => sub {
    is( is_blocked_path('lazysite/forms/submissions'),
        0, 'the directory itself is not blocked' );
    is( is_blocked_path('lazysite/forms/submissions/contact.jsonl'),
        0, 'and a store file under it stays reachable (unchanged)' );
    my $auth_why = is_blocked_path('lazysite/auth');
    ok( $auth_why, 'the auth tree stays blocked (control)' );
    like( $auth_why, qr/lazysite\/auth/, 'and the refusal names the path (SM730)' );
    ok( is_blocked_path('lazysite/forms/submissionsX'),
        'a sibling name-superset is NOT carved out (boundary-safe)' );
};

subtest 'the directory answers to the same capability as its files' => sub {
    my $req = carveout_requirement( 'lazysite/forms/submissions', 'read' );
    ok( $req, 'a listing of the store is capability-governed' );
    my %caps = map { $_ => 1 } @{ $req->{caps} || [] };
    ok( $caps{read_submissions} || $caps{manage_forms},
        'by the submissions capability, same as the files' )
        or diag explain $req;
};

subtest 'the listing the panel makes now answers' => sub {
    my $r = action_list('/lazysite/forms/submissions/');
    ok( $r->{ok}, 'action=list on the store directory succeeds' )
        or diag explain $r;
    ok( ( grep { ( $_->{name} // '' ) eq 'contact.jsonl' } @{ $r->{entries} || [] } ),
        'and shows the store the API reads' );
};

done_testing();
