package Odoo::Test::HttpCount;

use strict;
use warnings;
use HTTP::Tiny;

# Counts the HTTP requests a process makes, for the latency test: loaded into the daemon with
# PERL5OPT=-MOdoo::Test::HttpCount, it appends one line (the method and the path, never a header, cookie or body) to
# the file ODOO_OOM_HTTP_COUNT names for each request HTTP::Tiny sends. The test process loads it the same way and
# asks count(). Not part of OOM: a test's view of the wire.

our $COUNT = 0;
my $orig = \&HTTP::Tiny::request;
{
    no warnings 'redefine';
    *HTTP::Tiny::request = sub {
        my ( $self, $method, $url, @rest ) = @_;
        $COUNT++;
        if ( defined( my $f = $ENV{ODOO_OOM_HTTP_COUNT} ) ) {
            if ( open my $fh, '>>', $f ) {
                my ($path) = $url =~ m{^https?://[^/]+(/[^?]*)};
                print {$fh} "$method ", $path // '/', "\n";
                close $fh;
            }
        }
        return $orig->( $self, $method, $url, @rest );
    };
}

sub count { $COUNT }

1;
