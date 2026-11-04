#!/usr/bin/perl
# SM1310 (ruling 51 (a), T-06): replace_text saves with the modification time it
# read, so a page another writer saved between its read and its save is refused
# rather than overwritten. It passed undef, which skips action_save's conflict
# check: of two agents replacing text on one page at once, both answered
# "replacements: 1" and the later save wrote back the page it had read, without
# the other's change.
#
# THE TWO WRITERS. replace_text reads and saves inside one call, so the second
# writer is put between the two: the child loads the MCP script through a
# wrapper that lets Files::action_read return and then lands another writer's
# save on the page, a few seconds later by the clock (utime), as a save that
# finished first would leave it. With the fix reverted the call answers
# "replacements: 1" and the other writer's line is gone. The single writer is
# the control.
use strict;
use warnings;
use Test::More;
use JSON::PP   qw(encode_json decode_json);
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(site_tempdir run_child);

my $root = "$FindBin::Bin/../../..";
my $d    = site_tempdir();
make_path( "$d/lazysite/auth", "$d/lazysite/logs", "$d/content" );
sub put {
    my ( $rel, $text ) = @_;
    open my $f, '>', "$d/$rel" or die "$rel: $!";
    print {$f} $text;
    close $f;
}
sub slurp { open my $f, '<', "$d/$_[0]" or return ''; local $/; my $c = <$f>; close $f; return $c }
put( 'lazysite/lazysite.conf', "site_name: T\nmcp_enabled: true\n" );
put( 'lazysite/auth/users',    "agent:x\n" );

my $stub = "$d/users-stub.pl";
put( 'users-stub.pl', <<'STUB' );
#!/usr/bin/perl
use strict; use warnings; use JSON::PP qw(encode_json);
print encode_json({ ok => 1, settings => { mcp => 1, manage_content => 1 } });
STUB
chmod 0755, $stub;

# The second writer, landed after replace_text's read returns, when asked.
my $wrap = "$d/mcp-with-a-second-writer.pl";
put( 'mcp-with-a-second-writer.pl', <<"WRAP" );
use strict; use warnings;
use lib '$root/lib';
require Lazysite::Manager::Files;
my \$orig = \\&Lazysite::Manager::Files::action_read;
{
    no warnings 'redefine';
    *Lazysite::Manager::Files::action_read = sub {
        my \$r = \$orig->(\@_);
        if ( \$ENV{T_SECOND_WRITER} && ref \$r eq 'HASH' && \$r->{ok} ) {
            my \$f = \$ENV{DOCUMENT_ROOT} . '/content/page.md';
            open my \$fh, '>', \$f or die \$!;
            print {\$fh} \$r->{content} . "OTHER WRITER'S LINE\\n";
            close \$fh;
            utime( \$r->{mtime} + 5, \$r->{mtime} + 5, \$f );
        }
        return \$r;
    };
}
do '$root/lazysite-mcp.pl';
die \$@ if \$@;
WRAP

sub replace_text {
    my ( $old, $new, $second ) = @_;
    my $body = encode_json( { jsonrpc => '2.0', id => 1, method => 'tools/call',
            params => { name => 'replace_text', arguments => { path => '/content/page.md', old => $old, new => $new } } } );
    local %ENV = %ENV;
    $ENV{DOCUMENT_ROOT}       = $d;
    $ENV{REQUEST_METHOD}      = 'POST';
    $ENV{CONTENT_LENGTH}      = length $body;
    $ENV{LAZYSITE_USERS_TOOL} = $stub;
    $ENV{HTTP_AUTHORIZATION}  = 'Bearer agent:lzs_tok';
    $ENV{T_SECOND_WRITER}     = $second ? 1 : 0;
    my $resp = run_child( [ $^X, $wrap ], stdin => $body, stderr => 'inherit' )->{out};
    my ($jb) = $resp =~ /\r?\n\r?\n(.*)/s;
    my $j = ( defined $jb && length $jb ) ? eval { decode_json($jb) } : undef;
    return $j && $j->{result} ? $j->{result}{structuredContent} : $j;
}

sub fresh_page {
    put( 'content/page.md', "---\ntitle: P\n---\nFirst line.\nSecond line.\n" );
    utime( time - 60, time - 60, "$d/content/page.md" );
}

subtest 'one writer replaces text (control)' => sub {
    fresh_page();
    my $r = replace_text( 'First line.', 'First line, edited.' );
    ok( $r && $r->{ok}, 'saved' ) or diag explain $r;
    is( $r->{replacements}, 1, 'one replacement' );
    like( slurp('content/page.md'), qr/First line, edited\./, 'and the page carries it' );
};

subtest 'a page changed between the read and the save is refused, not overwritten' => sub {
    fresh_page();
    my $r = replace_text( 'Second line.', 'Second line, edited.', 1 );
    ok( $r && !$r->{ok}, 'refused' ) or diag explain $r;
    ok( $r->{conflict}, 'as a conflict' );
    is( $r->{kind} // '', 'conflict', 'of kind conflict' );
    like( $r->{error} // '', qr/Run replace_text again/, 'telling the agent to run it again' );
    my $page = slurp('content/page.md');
    like( $page, qr/OTHER WRITER'S LINE/, 'the other writer\'s change is kept' );
    unlike( $page, qr/Second line, edited\./, 'and this one was not written over it' );

    my $again = replace_text( 'Second line.', 'Second line, edited.' );
    ok( $again && $again->{ok}, 'run again, it reads the page afresh and saves' ) or diag explain $again;
    my $both = slurp('content/page.md');
    ok( $both =~ /OTHER WRITER'S LINE/ && $both =~ /Second line, edited\./, 'and both changes are there' );
};

done_testing;
