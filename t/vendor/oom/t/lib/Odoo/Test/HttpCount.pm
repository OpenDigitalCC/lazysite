package Odoo::Test::HttpCount;

use strict;
use warnings;
use HTTP::Tiny;
use Time::HiRes ();

# Counts the HTTP requests a process makes, for the latency test: loaded into the daemon with
# PERL5OPT=-MOdoo::Test::HttpCount, it appends one line (the method and the path, never a header, cookie or body, and the milliseconds the request took) to
# the file ODOO_OOM_HTTP_COUNT names for each request HTTP::Tiny sends. A JSON-RPC request also names what it
# asks (the service and method, or the model and method: never an argument). The test process loads it the same way and
# asks count(). Not part of OOM: a test's view of the wire.

our $COUNT = 0;
my $orig = \&HTTP::Tiny::request;
{
    no warnings 'redefine';
    *HTTP::Tiny::request = sub {
        my ( $self, $method, $url, @rest ) = @_;
        $COUNT++;
        my $f = $ENV{ODOO_OOM_HTTP_COUNT};
        return $orig->( $self, $method, $url, @rest ) if !defined $f;
        my ($path) = $url =~ m{^https?://[^/]+(/[^?]*)};
        my $what = '';
        my $body = ref $rest[0] eq 'HASH' ? $rest[0]{content} : undef;
        if ( defined $body && !ref $body && $body =~ /"service"\s*:\s*"(\w+)"/ ) {
            my $svc = $1;
            # execute_kw: args are [db, uid, credential, model, method, ...]; the credential is skipped, never read
            if ( $body =~ /"method"\s*:\s*"(execute_kw|execute)"/ && $body =~ /"args"\s*:\s*\[\s*"[^"]*"\s*,\s*[^,]+,\s*"(?:[^"\\]|\\.)*"\s*,\s*"([\w.]+)"\s*,\s*"(\w+)"/ ) { $what = " $1.$2" }
            elsif ( $body =~ /"method"\s*:\s*"(\w+)"/ ) { $what = " $svc.$1" }
        }
        my $t0  = Time::HiRes::time();
        my @res = wantarray ? $orig->( $self, $method, $url, @rest ) : scalar $orig->( $self, $method, $url, @rest );
        my $ms  = ( Time::HiRes::time() - $t0 ) * 1000;
        # written after the answer, so a line is a request that has finished; the last field is the milliseconds it took
        if ( open my $fh, '>>', $f ) { printf {$fh} "%s %s%s\t%.1f\n", $method, $path // '/', $what, $ms; close $fh }
        return wantarray ? @res : $res[0];
    };
}

sub count { $COUNT }

1;
