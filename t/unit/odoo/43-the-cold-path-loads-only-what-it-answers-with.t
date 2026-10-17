#!/usr/bin/perl
# SM1147 (OOM Lab P4): every request to the Odoo endpoint started two Perl
# programs and loaded Lazysite::Odoo with Egress under it before it looked at the
# request - including `?csrf=1`, the call every page makes first, which answers
# from the visitor and session cookies alone. The engine, its binding and field
# modules and OOM are now loaded only by a branch that reaches Odoo.
#
# Each case runs the real endpoint in a FRESH perl (so %INC is the request's own)
# and lists the modules it had loaded when it answered.
use strict;
use warnings;
use Test::More;
use JSON::PP qw(encode_json);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use lib "$FindBin::Bin/../../../lib";
use TestHelper qw(repo_root setup_minimal_site);
use OdooTest   qw(oom_or_skip shop_ready bind oom_lib oom_test_lib odoo_site);

BEGIN { oom_or_skip() }

my $root = repo_root();
my ( $d, undef ) = shop_ready();
setup_minimal_site($d);
odoo_site($d);
bind( $d, id => 'shared', operation => 'shop.products', modes => 'public' );

# The modules a fresh endpoint process had loaded when it had answered.
sub loaded_after {
    my ( $method, $query, $body ) = @_;
    my $code = q{
        require $ARGV[0]; open my $real, '>&', \*STDOUT; open STDOUT, '>', '/dev/null';
        main::main();
        print {$real} join( ' ', sort grep { m{\A(?:Lazysite|Odoo)} } keys %INC ), "\n";
    };
    my $json = defined $body ? $body : '';
    local %ENV = ( PATH => $ENV{PATH}, DOCUMENT_ROOT => $d, REQUEST_METHOD => $method, QUERY_STRING => $query // '',
        REMOTE_ADDR => '198.51.100.3', SCRIPT_NAME => '/cgi-bin/lazysite-odoo.pl', CONTENT_LENGTH => length $json,
        HTTP_HOST => 'localhost', PERL5LIB => join( ':', oom_lib(), oom_test_lib(), "$root/lib", "$root/t/lib" ) );
    my $in = "$d/in.json";
    open my $fh, '>', $in or die $!;
    print {$fh} $json;
    close $fh;
    my $pid = open my $out, '-|' // die $!;
    if ( !$pid ) {
        open STDIN,  '<', $in or die $!;
        open STDERR, '>', '/dev/null';
        exec $^X, '-e', $code, "$root/lazysite-odoo.pl" or die $!;
    }
    my $l = <$out>;
    close $out;
    return { map { $_ => 1 } split ' ', $l // '' };
}

my @engine = qw(Lazysite/Odoo.pm Lazysite/Egress.pm Lazysite/Odoo/Binding.pm Lazysite/Odoo/Fields.pm);
sub names { my ($h) = @_; return { map { ( s{/}{::}gr =~ s{\.pm\z}{}r ) => 1 } keys %$h } }

subtest '?csrf=1 loads no engine and no OOM' => sub {
    my $m = names( loaded_after( 'GET', 'csrf=1' ) );
    ok( $m->{'Lazysite::Odoo::Visitor'}, 'it did answer (the visitor module is loaded)' ) or diag join ' ', sort keys %$m;
    for my $e ( map { s{/}{::}gr =~ s{\.pm\z}{}r } @engine, 'Odoo/Ops.pm' ) {
        ok( !$m->{$e}, "$e is not loaded" );
    }
    is( scalar( grep { /\AOdoo::/ } keys %$m ), 0, 'no OOM module at all' );
};

subtest 'a request refused before it reaches Odoo loads no engine either' => sub {
    my $m = names( loaded_after( 'POST', '', 'not json' ) );
    ok( !$m->{'Lazysite::Odoo'}, 'a body that is not JSON: no engine' );
    $m = names( loaded_after( 'POST', '', encode_json( { signin => 1, login => 'a', password => 'b' } ) ) );
    ok( !$m->{'Lazysite::Odoo'}, 'a sign-in with no token: refused, and no engine' );
    $m = names( loaded_after( 'PUT', '' ) );
    ok( !$m->{'Lazysite::Odoo'}, 'the wrong method: no engine' );
};

subtest 'a branch that reaches Odoo does load it (the control)' => sub {
    my $m = names( loaded_after( 'GET', 'binding=shared' ) );
    ok( $m->{'Lazysite::Odoo'},           'a binding read loads the engine' );
    ok( $m->{'Lazysite::Odoo::Binding'},  'and the binding module' );
    ok( $m->{'Odoo::Ops'},                'and OOM' );
};

done_testing;
