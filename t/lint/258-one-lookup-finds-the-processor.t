#!/usr/bin/perl
# SM1066: ONE LOOKUP FINDS THE PROCESSOR for every preview.
#
# Two rules found it until SM1066 - Manager::Common::processor_path and MCP's
# _processor_tool - and they disagreed on an install whose cgi-bin is not the
# docroot's ../cgi-bin, so two MCP previews shelled a processor that was not
# there while the third rendered (SM1065). Lazysite::Paths::find_processor is
# now the one rule. This holds it there: both callers go through it, and no
# other library or previewing CGI builds a path to lazysite-processor.pl.
#
# Out of scope, on purpose: lazysite-auth.pl (the wrapper EXECS the CGI the
# web server named, which is not finding a processor to render a preview with),
# lazysite-front.pl (routes by LAZYSITE_CGIBIN), tools/lazysite-server.pl (the
# dev server's own --processor), and plugins.
use strict;
use warnings;
use Test::More;
use File::Find;
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root);

my $root = repo_root();

sub slurp { open my $fh, '<', $_[0] or die "open $_[0]: $!"; local $/; return scalar <$fh> }

sub body_of {
    my ( $text, $sub ) = @_;
    my ($body) = $text =~ m{^sub \Q$sub\E \{\n(.*?)^\}}ms;
    return $body;
}

my $common = body_of( slurp("$root/lib/Lazysite/Manager/Common.pm"), 'processor_path' );
ok( defined $common, 'Manager::Common::processor_path exists' );
like( $common // '', qr/Lazysite::Paths::find_processor\(/, 'and asks Lazysite::Paths::find_processor' );

my $mcp = body_of( slurp("$root/lazysite-mcp.pl"), '_processor_tool' );
ok( defined $mcp, 'lazysite-mcp.pl _processor_tool exists' );
like( $mcp // '', qr/Lazysite::Paths::find_processor\(/, 'and asks Lazysite::Paths::find_processor' );

my @files = map {"$root/$_"} qw(lazysite-mcp.pl lazysite-manager-api.pl lazysite-data.pl lazysite-dav.pl);
find( { no_chdir => 1, wanted => sub { push @files, $_ if /\.pm\z/ } }, "$root/lib" );

my @hits;
for my $f ( sort @files ) {
    next if $f eq "$root/lib/Lazysite/Paths.pm";
    open my $fh, '<', $f or die "$f: $!";
    while ( my $line = <$fh> ) {
        next if $line =~ /\A\s*#/;
        ( my $code = $line ) =~ s/\s#.*//;
        push @hits, "$f:$.: $line" if $code =~ m{/lazysite-processor\.pl['"]};
    }
    close $fh;
}
is( scalar @hits, 0, 'no path to lazysite-processor.pl is built outside Lazysite::Paths' )
    or diag join '', @hits;

done_testing();
