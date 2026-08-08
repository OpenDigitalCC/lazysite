#!/usr/bin/perl
# SM255 (completion): lazysite.conf has exactly ONE writer.
#
# WHY THIS EXISTS. SM255 unified the two writers it found - config-set's and the
# domain verbs' - and its commit message asserted that all callers now shared a
# single path. That assertion was wrong: Lazysite::Manager::Plugins wrote the
# same file twice more by hand, once without committing and once with a private
# commit of its own, which is precisely the split SM255 set out to remove. It
# reached main and was caught by an unrelated test, three commits later.
#
# The lesson is not "look harder next time". A property asserted in a commit
# message is worth nothing; a property a test enforces cannot silently stop being
# true. So: no module may write lazysite.conf except Common's writer, and no
# module may commit that path itself.
#
# WHAT COUNTS AS A WRITE. Opening the path for output, or handing it to
# write_file_checked / a rename. Reads are fine and common - plenty of code
# parses the conf, and this test must not make that awkward.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root);
use File::Find ();

my $root = repo_root();

# Common owns the writer; Git owns the commit primitive. The plugin that
# implements content history legitimately manages its own conf key at
# adoption time, before the writer is reachable.
my %EXEMPT = (
    'lib/Lazysite/Manager/Common.pm' => 'owns the single writer',
    'lib/Lazysite/Git.pm'            => 'owns the commit primitive',

    # Builds a throwaway site in a temp dir to measure against. There is no
    # live conf to lock against and no history to record into - it is creating
    # the file, not editing one.
    'tools/bench.pl' => 'creates a benchmark fixture, not a live site conf',
);

my @sources;
File::Find::find(
    {   no_chdir => 1,
        wanted   => sub {
            return unless /\.(?:pm|pl)\z/;
            return if $File::Find::name =~ m{/(?:t|tmp|dist|man|node_modules)/};
            push @sources, $File::Find::name;
        },
    },
    "$root/lib",
    "$root/tools",
    ( -d "$root/plugins" ? "$root/plugins" : () ),
);
# The CGI entry points live at the top level, not under lib/.
push @sources, grep { -f } map {"$root/$_"} qw(
    lazysite-manager-api.pl lazysite-mcp.pl lazysite-dav.pl
    lazysite-processor.pl install.pl
);

ok( scalar @sources, 'found sources to scan' );

my ( @writers, @committers );
for my $file (@sources) {
    my $rel = $file;
    $rel =~ s{\A\Q$root\E/}{};
    next if $EXEMPT{$rel};

    open my $fh, '<', $file or die "$file: $!";
    my $src = do { local $/; <$fh> };
    close $fh;

    # PER-SUB, not per-file. $conf_path is a common local name and several
    # modules use it for a DIFFERENT file in a different sub - Plugins writes a
    # plugin's own config_file that way. Judging a whole file at once cannot
    # tell those apart and reports the innocent sub alongside the guilty one.
    my @subs = split /^(?=sub\s+\w+)/m, $src;
    for my $body (@subs) {
        my ($sub) = $body =~ /\Asub\s+(\w+)/;
        $sub //= 'file scope';

        # Which local names hold the conf path IN THIS SUB, plus the literal.
        my @held = $body =~ /(\$\w+)\s*=\s*"[^"]*lazysite\/lazysite\.conf"/g;
        my $names = join '|', map {quotemeta} @held;
        my $target = $names
            ? qr/(?:\Q"\E[^"]*lazysite\/lazysite\.conf\Q"\E|$names)/
            : qr/"[^"]*lazysite\/lazysite\.conf"/;

        push @writers, "$rel: $sub (open for output)"
            if $body =~ /\bopen\s+my\s+\$\w+\s*,\s*'>[^']*'\s*,\s*$target/;
        push @writers, "$rel: $sub (write_file_checked)"
            if $body =~ /\bwrite_file_checked\s*\(\s*$target/;
    }

    # Committing the conf path directly re-creates the divergence even if the
    # write itself goes through the writer.
    push @committers, $rel
        if $src =~ /Lazysite::Git::commit_\w+\s*\([^)]*lazysite\/lazysite\.conf/s;
}

is_deeply( \@writers, [],
    'nothing writes lazysite.conf outside Common\'s single writer' )
    or diag( "Route these through Common::write_conf_key / write_conf_content:\n  "
        . join( "\n  ", @writers ) );

is_deeply( \@committers, [],
    'nothing commits lazysite.conf itself - the writer records it' )
    or diag( "Drop the private commit; the writer already records the change:\n  "
        . join( "\n  ", @committers ) );

# The exemptions must stay honest: Common really must contain the writer.
{
    open my $fh, '<', "$root/lib/Lazysite/Manager/Common.pm" or die $!;
    my $src = do { local $/; <$fh> };
    close $fh;
    like( $src, qr/sub _write_conf\b/, 'Common still defines the single writer' );
    like( $src, qr/sub write_conf_key\b/,     'and its per-key shape' );
    like( $src, qr/sub write_conf_content\b/, 'and its whole-file shape' );
}

done_testing();
