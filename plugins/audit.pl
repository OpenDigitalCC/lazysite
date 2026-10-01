#!/usr/bin/perl
# audit.pl - link audit for lazysite docroots
# Reports orphaned pages (exist but not linked) and broken links
#
# Usage: perl plugins/audit.pl [options] [docroot]
#
# Options:
#   --exclude path,path,...   comma-separated canonical paths to exclude
#   --exclude-file FILE       file containing one exclusion per line
#   --scan                    write Markdown report and output JSON
#   --describe                print plugin descriptor JSON and exit
#   --docroot PATH            set docroot explicitly

use strict;
use warnings;
use File::Find;
use File::Basename qw(dirname basename);
use POSIX          qw(strftime);
use File::Path     qw(make_path);
use Cwd            qw(abs_path);

BEGIN {
    # Locate the Lazysite module tree relative to this script (run-in-place,
    # tar and Hestia installs), falling back to the system @INC (package
    # installs). Nothing is loaded here: the loads are lazy, so --describe
    # answers even where the tree is not found.
    require Cwd;
    require File::Basename;
    my $bin = File::Basename::dirname( Cwd::abs_path(__FILE__) );
    for my $cand ( "$bin/lib", "$bin/../lib", "$bin/../../lib" ) {
        if ( -d "$cand/Lazysite" ) { unshift @INC, $cand; last }
    }
}

my $LOG_COMPONENT = 'audit';

# --- Image and asset extensions to ignore as link targets ---

my %IGNORE_EXT = map { $_ => 1 } qw(
    svg png jpg jpeg gif webp ico bmp tiff
    pdf zip tar gz bz2 xz
    css js woff woff2 ttf eot
    mp4 mp3 ogg webm
);

# SM922 fault 4: the system pages, resolved the way the engine resolves them - a
# site copy under the content root, else the protected engine default under
# lazysite/templates/system/ (lazysite-processor.pl:149). A link to one of these is
# only broken when NEITHER exists. The shipped check asserts /login answers 200
# while the audit reported it broken, on the same site at the same moment.
#
# UP HERE, ABOVE THE MAIN BODY, and that position is the whole of whether it works.
# This table was first written next to the sub that reads it - which is below the
# main body in this file - so at the moment collect_audit_results ran it was still
# EMPTY and the check silently did nothing. Measured, not reasoned: the before/after
# sweep still reported /login broken and that is what exposed it.
my %SYSTEM_PAGE = map { $_ => 1 } qw(login claim logout forgot 402 403 404);

# The page this plugin used to write its report into. Every site that has ever run
# the audit has one, and until the next scan removes it, it is sitting in the
# docroot full of last run's findings written as links.
#
# TWO USES, ONE SPELLING: the walks IGNORE it so no run reports it, and a scan
# DELETES it. The ignore is what makes the count stable on the very first run after
# an upgrade - the removal happens after the walk, so without this the first run
# would still report the stale page once and the operator would see the instability
# this filing is about one last time, on the run that was supposed to fix it.
my $LEGACY_REPORT_REL = 'manager/audit-report.md';

# --- Parse arguments ---

my %exclude;
my $DOCROOT;
my $SCAN_MODE = 0;

while (@ARGV) {
    my $arg = shift @ARGV;
    if ( $arg eq '--describe' ) {
        print_describe();
        exit 0;
    }
    elsif ( $arg eq '--scan' ) {
        $SCAN_MODE = 1;
    }
    elsif ( $arg eq '--docroot' ) {
        $DOCROOT = shift @ARGV;
    }
    elsif ( $arg eq '--exclude' ) {
        my $list = shift @ARGV or die "Missing value for --exclude\n";
        $exclude{$_} = 1 for split /,/, $list;
    }
    elsif ( $arg eq '--exclude-file' ) {
        my $file = shift @ARGV          or die "Missing value for --exclude-file\n";
        open( my $fh, '<:utf8', $file ) or die "Cannot read $file: $!\n";            # L-6
        while (<$fh>) {
            chomp;
            s/^\s+|\s+$//g;
            $exclude{$_} = 1 if length;
        }
        close $fh;
    }
    else {
        $DOCROOT = $arg unless $DOCROOT;
    }
}

$DOCROOT = abs_path( $DOCROOT || '.' );
die "Docroot not found: $DOCROOT\n" unless -d $DOCROOT;
# SM540: the forwarding conf peek looks under DOCUMENT_ROOT; --docroot is it.
$ENV{DOCUMENT_ROOT} //= $DOCROOT;

# Always exclude these from orphan report
$exclude{'404'} = 1;
$exclude{''}    = 1;

# --- Main ---

log_event( 'INFO', $DOCROOT, 'audit started' );

my $results = collect_audit_results();

log_event( 'INFO', $DOCROOT, 'audit complete', pages => scalar keys %{ $results->{pages} } );

if ($SCAN_MODE) {
    run_scan($results);
}
else {
    print_report($results);
}

# --- Collect results ---

sub collect_audit_results {
    my %pages;
    my %sources;
    my %inbound;
    my %outbound;

    find( sub {
            return unless -f;
            return unless /\.(md|url)$/;
            my $rel = _rel_of($File::Find::name);
            return if $rel =~ m{^lazysite/};
            return if $rel =~ m{(^|/)\.};
            return if $rel eq $LEGACY_REPORT_REL;    # SM922: not content
            my $canon = canonical($rel);
            $pages{$canon}   = 1;
            $sources{$canon} = $rel;
            # .url files are themselves reachable entry points
            push @{ $inbound{$canon} }, 'url-entrypoint' if /\.url$/;
    }, $DOCROOT );

    find( sub {
            return unless -f && /\.md$/;
            my $rel = _rel_of($File::Find::name);
            return if $rel =~ m{^lazysite/};
            return if $rel =~ m{(^|/)\.};
            return if $rel eq $LEGACY_REPORT_REL;    # SM922: not content
            extract_links( $File::Find::name, $rel, \%inbound, \%outbound );
            extract_scan_refs( $File::Find::name, $rel, \%inbound );
    }, $DOCROOT );

    find( sub {
            return unless -f && /\.url$/;
            my $rel = _rel_of($File::Find::name);
            return if $rel =~ m{(^|/)\.};
            ( my $html_path = $File::Find::name ) =~ s/\.url$/.html/;
            if ( -f $html_path ) {
                extract_links( $html_path, $rel, \%inbound, \%outbound );
            }
    }, $DOCROOT );

    if ( -d ( _lz($DOCROOT) . "/templates" ) ) {
        find( sub {
                return unless -f && /\.tt$/;
                my $rel = _rel_of($File::Find::name);
                return if $rel =~ m{(^|/)\.};
                extract_links( $File::Find::name, $rel, \%inbound, \%outbound );
        }, _lz($DOCROOT) . "/templates" );
    }

    my @orphans;
    for my $canon ( sort keys %pages ) {
        next if $exclude{$canon};
        push @orphans, $canon unless $inbound{$canon};
    }

    # SM922 fault 5, and the 2026-09-30 ruling: WITHHELD IS NOT ABSENT.
    #
    # The audit resolves as an anonymous visitor and keeps doing so - resolving as
    # the operator was declined, because this report is read by whoever can open it
    # and naming the paths of pages a reader cannot see would be a disclosure this
    # work would have created. But a page that EXISTS and is gated is not a broken
    # link, and reporting it as one is the four-state fault: a draft section made
    # every link into it look dead to the only audience that can see it.
    #
    # The private store is where gated content lives (SM286), so a target found
    # there is reported as its own state. What this does NOT do - and the ruling
    # says so plainly - is confirm the link resolves: it says the audit declined to
    # judge it.
    my %withheld_page = %{ _private_pages() };

    my %seen_broken;
    my ( @broken, @withheld );
    for my $source ( sort keys %outbound ) {
        for my $target ( @{ $outbound{$source} } ) {
            next if $pages{$target};
            ( my $with_index = $target ) =~ s{/index$}{};
            next if $pages{$with_index};
            # SM558: a bare `index` (and index.html, which the collector has
            # already stripped to `index`) is the ROOT page - the same mapping
            # canonical() applies to index.md, whose key is the empty string.
            next if $target eq 'index' && $pages{''};

            # SM922 fault 4: a system page answers through the fallback chain, so
            # it is not missing just because no file sits in the docroot. The
            # shipped check asserts /login resolves 200 while the audit reported it
            # broken, on the same site at the same moment - and the check was right.
            next if _system_page_resolves($target);

            next if $seen_broken{"$source->$target"}++;
            if ( $withheld_page{$target} || $withheld_page{$with_index} ) {
                push @withheld, { source => $source, target => $target };
                next;
            }
            push @broken, { source => $source, target => $target };
        }
    }

    return {
        pages    => \%pages,
        sources  => \%sources,
        broken   => \@broken,
        withheld => \@withheld,
        orphaned => \@orphans,
    };
}

sub _system_page_resolves {
    my ($target) = @_;
    return 0 unless $SYSTEM_PAGE{$target};
    return 1 if -f "$DOCROOT/$target.md" || -f "$DOCROOT/$target.html";
    return 1 if -f ( _lz($DOCROOT) . "/templates/system/$target.md" );
    return 0;
}

# Pages in the private store, as canonical keys. Standalone plugin: the store's
# name is composed here rather than through Lazysite::Private, which is the same
# arrangement the alias-cache sweep in run_scan already uses - and the one place
# this file would have to change if that naming ever moves.
sub _private_pages {
    my %found;
    my $root = dirname($DOCROOT) . '/' . basename($DOCROOT) . '-lazysite-private';
    return \%found unless -d $root;
    find( sub {
            return unless -f && /\.(?:md|url)$/;    # non-capturing: perlcritic sev-3
            ( my $rel = $File::Find::name ) =~ s{^\Q$root\E/}{};
            return if $rel =~ m{(^|/)\.};
            $found{ canonical($rel) } = 1;
    }, $root );
    return \%found;
}

# --- Scan mode ---

# SM922 fault 6 AND the two things that share its root: THE REPORT STOPS BEING A
# PAGE IN THE DOCROOT.
#
# It was written to manager/audit-report.md, which caused three separate symptoms
# the filing and the release manager found independently:
#
#   - the audit SCANNED ITS OWN LAST REPORT, so each run re-reported the previous
#     run's findings as broken links on that page. The count moved 10 -> 8 -> 10 ->
#     7 with no change to the site, which is what made it untrustworthy;
#   - the result was displayed by FETCHING A URL into a static card, with no way to
#     re-run it from where you were reading it;
#   - and it is why resolving as the operator was declined: a report in the docroot
#     is fetchable by whoever can open it, so naming gated paths in it would have
#     been a disclosure.
#
# The report is now a STORE under lazysite/, which the page walks already skip by
# path, so the audit cannot find it however the extractor changes. The action
# returns the findings in its own result, so the manager renders them directly.
#
# THE OLD PAGE IS DELETED ON RUN. Every site that has run this plugin has one in its
# docroot; leaving it would leave a stale report readable at a URL that nothing
# updates, which is worse than removing it.
sub run_scan {
    my ($results) = @_;

    my $store_dir = _lz($DOCROOT) . "/audit";
    make_path($store_dir) unless -d $store_dir;
    my $store_path = "$store_dir/link-report.json";

    require JSON::PP;
    my %report = (
        generated     => POSIX::strftime( '%Y-%m-%dT%H:%M:%S', localtime ),
        generated_ymd => POSIX::strftime( '%Y-%m-%d %H:%M:%S', localtime ),
        broken        => $results->{broken}   // [],
        withheld      => $results->{withheld} // [],
        orphaned      => [ map { { page => $_ } } @{ $results->{orphaned} // [] } ],
        pages         => scalar keys %{ $results->{pages} },
    );

    if ( open my $fh, '>:utf8', $store_path ) {
        print {$fh} JSON::PP->new->canonical->pretty->encode( \%report );
        close $fh;
        log_event( 'INFO', $DOCROOT, 'report written', path => $store_path );
    }
    else {
        # The findings still go back to the caller: a store this process cannot
        # write is worth saying out loud and is not a reason to answer nothing.
        log_event( 'WARN', $DOCROOT, 'cannot write the audit report store',
            path => $store_path, error => "$!" );
    }

    _remove_legacy_report_page();

    print JSON::PP::encode_json( {
            ok       => 1,
            report   => \%report,
            broken   => scalar @{ $results->{broken} },
            withheld => scalar @{ $results->{withheld} // [] },
            orphaned => scalar @{ $results->{orphaned} },
    } );
}

# The page this plugin used to write, and its renders. Every site that ran the
# audit before 0.15.2 has one.
sub _remove_legacy_report_page {
    my @gone;
    ( my $html = $LEGACY_REPORT_REL ) =~ s/\.md\z/.html/;
    for my $f ( "$DOCROOT/$LEGACY_REPORT_REL", "$DOCROOT/$html" ) {
        push @gone, $f if -f $f && unlink $f;
    }
    # SM110: the per-alias-host copies of the render too (standalone plugin -
    # inline rather than the Lazysite::Util helper).
    my $hosts_dir = _lz($DOCROOT) . "/cache/hosts";
    if ( opendir( my $hd, $hosts_dir ) ) {
        for my $h ( readdir $hd ) {
            next if $h =~ /^\./;
            my $copy = "$hosts_dir/$h/manager/audit-report.html";
            push @gone, $copy if -f $copy && unlink $copy;
        }
        closedir $hd;
    }
    log_event( 'INFO', $DOCROOT, 'removed the report page this plugin used to write',
        files => join( ', ', @gone ) )
        if @gone;
    return;
}

# --- CLI report ---

sub print_report {
    my ($results) = @_;
    my $broken    = $results->{broken};
    my $orphaned  = $results->{orphaned};
    my $pages     = $results->{pages};
    my $sources   = $results->{sources};

    print "lazysite link audit: $DOCROOT\n";
    print "=" x 60 . "\n\n";

    print "ORPHANED PAGES (" . scalar(@$orphaned) . ")\n";
    print "Exist but are not linked from any scanned file.\n\n";
    if (@$orphaned) {
        printf "  %-40s  %s\n", "/$_", $sources->{$_} // '' for @$orphaned;
    }
    else { print "  None found.\n"; }

    print "\nBROKEN LINKS (" . scalar(@$broken) . ")\n";
    print "Links pointing to pages that do not exist.\n\n";
    if (@$broken) {
        for my $b ( sort { $a->{source} cmp $b->{source} } @$broken ) {
            printf "  %-40s  -> /%s\n", $b->{source}, $b->{target};
        }
    }
    else { print "  None found.\n"; }

    # SM922: its own section, not mixed into the broken list. `withheld` is not
    # `absent`, and the difference is the difference between "fix this" and
    # "nothing to do here".
    my $withheld = $results->{withheld} // [];
    print "\nWITHHELD TARGETS (" . scalar(@$withheld) . ")\n";
    print "Pages that exist but are not visible to an anonymous visitor, so this\n"
        . "audit declined to judge the link. NOT reported as broken, and NOT\n"
        . "confirmed as resolving either.\n\n";
    if (@$withheld) {
        for my $w ( sort { $a->{source} cmp $b->{source} } @$withheld ) {
            printf "  %-40s  -> /%s\n", $w->{source}, $w->{target};
        }
    }
    else { print "  None found.\n"; }

    print "\nSUMMARY\n";
    printf "  Source pages:    %d\n", scalar keys %$pages;
    printf "  Orphaned:        %d\n", scalar @$orphaned;
    printf "  Broken links:    %d\n", scalar @$broken;
    printf "  Withheld:        %d\n", scalar @$withheld;
    print "\n";
}

# --- Plugin descriptor ---

sub print_describe {
    require JSON::PP;
    print JSON::PP::encode_json( {
            id            => 'link-audit',
            name          => 'Link Audit',
            description   => 'Scan for broken internal links and orphaned pages',
            version       => '1.0',
            config_file   => '',
            config_schema => [],
            # SM922: NO `on_complete => open_url` any more. The report was a page in
            # the docroot and the result was a URL to fetch into a static card;
            # it is a store now and the findings come back IN this action's result,
            # so the manager opens them in a modal it can refresh from.
            actions => [
                {
                    id    => 'run',
                    label => 'Run audit',
                    confirm => 'This will scan all pages and may take a moment on large sites.',
                    endpoint => 'plugin-action',
                }
            ],
    } );
}

# --- Utilities ---

# A found path, relative to the docroot. The SKIPS deliberately stay with each
# caller: the .url walk does NOT skip lazysite/ and the others do, which is a
# real divergence and not this helper's to decide.
sub _rel_of {
    my ($abs) = @_;
    ( my $rel = $abs ) =~ s{^\Q$DOCROOT\E/}{};
    return $rel;
}

sub canonical {
    my ($rel) = @_;
    $rel =~ s/\.(md|url|html)$//;
    $rel =~ s{/index$}{};
    $rel =~ s{^index$}{};
    $rel =~ s{/$}{};
    return $rel;
}

# SM922 fault 1 and 2: A LINK IS SOMETHING IN PROSE.
#
# The extractor read the whole file, so `body.innerHTML = BUILD[listId](key);`
# inside a `<script>` block matched the markdown-link pattern and `key` was
# reported as a broken link. So did `![](img/...)` and `[Book a visit](/visit)`
# inside fenced examples. THE CORPUS GUARANTEES THIS: the docs the engine ships
# into every docroot are precisely the pages that contain example markup and
# embedded scripts, so every operator who ran the audit saw it.
#
# Removed before extraction, in this order: fenced blocks (``` and ~~~, any
# indent, any info string), `<script>` and `<style>` elements, markdown indented
# code blocks, and inline code spans. The replacement keeps the NEWLINES of what
# it removes, so nothing downstream that counts lines is thrown out - the report
# does not cite lines today, and a blanking that silently renumbered them would be
# a trap for whoever adds that.
sub prose_only {
    my ($content) = @_;
    return '' unless defined $content;

    my $blank = sub { my $s = shift; $s =~ s/[^\n]//g; return $s };

    # Fenced blocks first: a fence can contain anything, including a `<script>`
    # open with no close, so taking them out before the element passes keeps a
    # malformed example from eating the rest of the page.
    $content =~ s/^([ \t]*)(`{3,}|~{3,})[^\n]*\n(.*?)(?:^[ \t]*\2[^\n]*\n|\z)/$blank->($&)/gmse;

    $content =~ s{<script\b.*?</script\s*>}{$blank->($&)}gise;
    $content =~ s{<style\b.*?</style\s*>}{$blank->($&)}gise;

    # An indented code block: four spaces or a tab, after a blank line. The
    # blank-line condition is what keeps a wrapped list item from being read as
    # code - a continuation line is indented too, and the docs are full of them.
    my @out;
    my $prev_blank = 1;
    for my $line ( split /\n/, $content, -1 ) {
        if ( $prev_blank && $line =~ /^(?: {4,}|\t)\S/ ) {
            push @out, '';
            next;    # stays blank; $prev_blank is false, so the block continues
        }
        if ( @out && $out[-1] eq '' && $line =~ /^(?: {4,}|\t)/ && $line =~ /\S/ ) {
            push @out, '';
            next;
        }
        push @out, $line;
        $prev_blank = ( $line =~ /\S/ ) ? 0 : 1;
    }
    $content = join "\n", @out;

    # Inline code spans last, so a `[link](x)` written as an example inside
    # backticks is not a link either.
    $content =~ s/(`+)(?:(?!\1).)*?\1/ /gs;

    return $content;
}

# SM922 fault 3: A RELATIVE LINK IS RELATIVE TO THE PAGE IT IS ON.
#
# `s{^/}{}` treated every link as absolute, so `key` on /manager/handlers was
# recorded as `key` and reported as `/key` - a path that does not exist and was
# never written. The site resolves it against the page's own directory, and so does
# this now, including `../`.
sub resolve_link_target {
    my ( $link, $source_rel ) = @_;

    my $abs;
    if ( $link =~ m{^/} ) {
        ( $abs = $link ) =~ s{^/+}{};
    }
    else {
        my $dir = $source_rel;
        $dir =~ s{[^/]*\z}{};    # keep the trailing slash, or empty at the root
        $abs = $dir . $link;
    }

    # Collapse . and .. the way a browser does, so a link that climbs out of the
    # docroot is dropped rather than becoming a path with `..` still in it.
    my @parts;
    for my $seg ( split m{/}, $abs, -1 ) {
        next if $seg eq '' || $seg eq '.';
        if ( $seg eq '..' ) {
            return undef unless @parts;
            pop @parts;
            next;
        }
        push @parts, $seg;
    }
    return join '/', @parts;
}

sub extract_links {
    my ( $path, $label, $inbound, $outbound ) = @_;

    open( my $fh, '<:utf8', $path ) or return;
    my $content = do { local $/; <$fh> };
    close $fh;

    $content = prose_only($content);

    my @raw_links;
    while ( $content =~ /\[(?:[^\]]*)\]\(([^)]+)\)/g ) {
        push @raw_links, $1;
    }
    while ( $content =~ /(?:href|src)\s*=\s*["']([^"']+)["']/g ) {
        push @raw_links, $1;
    }

    for my $link (@raw_links) {
        next if $link =~ /\[%/;
        next if $link =~ m{^https?://};
        next if $link =~ m{^mailto:};
        next if $link =~ m{^#};
        next if $link =~ m{^data:};
        next if $link eq 'about:blank';

        $link =~ s/[?#].*$//;
        next unless length $link;

        if ( $link =~ /\.(\w+)$/ ) {
            next if $IGNORE_EXT{ lc($1) };
        }

        # The page this link is ON, as a directory - a .url or .tt label resolves
        # the same way its rendered page does.
        my $target = resolve_link_target( $link, $label );
        next unless defined $target && length $target;
        next if $target =~ m{^assets/};

        $target =~ s/\.(html|md|url)$//;
        $target =~ s{/$}{};
        next unless length $target;

        push @{ $inbound->{$target} }, $label;
        push @{ $outbound->{$label} }, $target;
    }
}

# Parse tt_page_var frontmatter block for scan:/path patterns and mark
# every matching .md file as reachable in %inbound. Mirrors resolve_scan
# in lazysite-processor.pl so pages included via scan aren't orphaned.
sub extract_scan_refs {
    my ( $path, $label, $inbound ) = @_;

    open( my $fh, '<:utf8', $path ) or return;
    my @lines = <$fh>;
    close $fh;

    return unless @lines && $lines[0] =~ /^---\s*$/;

    my $in_tt_vars = 0;
    for my $i ( 1 .. $#lines ) {
        last if $lines[$i] =~ /^---\s*$/;

        if ( $lines[$i] =~ /^tt_page_var\s*:\s*$/ ) {
            $in_tt_vars = 1;
            next;
        }
        next unless $in_tt_vars;
        # Leaving the tt_page_var block when an unindented key appears
        if ( $lines[$i] =~ /^\S/ ) { $in_tt_vars = 0; next }

        if ( $lines[$i] =~ /^\s+\w[\w-]*\s*:\s*scan:(\S+)/ ) {
            resolve_scan_for_audit( $1, $label, $inbound );
        }
    }
}

sub resolve_scan_for_audit {
    my ( $pattern, $label, $inbound ) = @_;
    return unless $pattern =~ m{^/};
    my $fs_pattern = $DOCROOT . $pattern;
    return unless $fs_pattern =~ /\.md$/;

    my @files;
    if ( $fs_pattern =~ m{\*\*} ) {
        my ( $base, $rest ) = $fs_pattern =~ m{^(.*?)/\*\*/(.*)$};
        if ( defined $base && defined $rest && -d $base ) {
            my $file_re = $rest;
            $file_re =~ s/\./\\./g;
            $file_re =~ s/\*/.*/g;
            $file_re = qr/\A${file_re}\z/;
            my @queue = ($base);
            while ( my $dir = shift @queue ) {
                opendir( my $dh, $dir ) or next;
                for my $entry ( readdir($dh) ) {
                    next if $entry =~ /^\./;
                    my $p = "$dir/$entry";
                    if    ( -d $p )              { push @queue, $p }
                    elsif ( $entry =~ $file_re ) { push @files, $p }
                }
                closedir($dh);
            }
        }
    }
    else {
        @files = glob($fs_pattern);
    }

    for my $f (@files) {
        my $rel   = _rel_of($f);
        my $canon = canonical($rel);
        push @{ $inbound->{$canon} }, "scan:$label";
    }
}

# The manager's edit link for a source file.
sub uri_encode {
    my ($str) = @_;
    $str =~ s/([^a-zA-Z0-9_.~-])/sprintf('%%%02X', ord($1))/ge;
    return $str;
}

# --- Logging ---

sub log_event {
    my ( $level, $context, $message, %extra ) = @_;
    my $min_level = $ENV{LAZYSITE_LOG_LEVEL} // 'INFO';
    my %rank      = ( DEBUG => 0, INFO => 1, WARN => 2, ERROR => 3 );
    return if ( $rank{$level} // 1 ) < ( $rank{$min_level} // 1 );
    my $ts     = strftime( '%Y-%m-%d %H:%M:%S', localtime );
    my $format = $ENV{LAZYSITE_LOG_FORMAT} // 'text';
    if ( $format eq 'json' ) {
        my $pairs = join ',',
            map { '"' . _json_str($_) . '":"' . _json_str( $extra{$_} ) . '"' }
            keys %extra;
        my $json = '{"ts":"' . $ts . '"'
            . ',"level":"' . _json_str($level) . '"'
            . ',"component":"' . _json_str($LOG_COMPONENT) . '"'
            . ',"context":"' . _json_str($context) . '"'
            . ',"message":"' . _json_str($message) . '"'
            . ( $pairs ? ",$pairs" : '' )
            . '}';
        print STDERR "$json\n";
        _forward_diag( $level, $json );
    }
    else {
        my $extras = join ' ',
            map { "$_=" . $extra{$_} } keys %extra;
        my $line = "[$ts] [$level] [$LOG_COMPONENT] [$context] $message";
        $line .= " $extras" if $extras;
        print STDERR "$line\n";
        _forward_diag( $level, $line );
    }
}

# SM850: the engine's tree - inside the docroot, or beside it on a site that
# moved it out (SM293). Asked of the resolver, never built by hand: a path built
# here kept working until the day a site migrated, then read and wrote a
# directory that was no longer there.
sub _lz {
    my ($docroot) = @_;
    require Lazysite::Paths;
    return Lazysite::Paths::lazysite_dir($docroot);
}

# SM540: a best-effort copy of the line to syslog through Lazysite::Util's
# forward_line, so this plugin's diagnostics are covered by the
# forward_diagnostics DEFAULT of WARN and above (SM932) as well as by an
# explicit setting - it needed `forward_diagnostics: true` before that, and
# the docs promised syslog either way. The rest of this plugin's
# diagnostics as the docs promise. The module tree is found by the bootstrap at
# the top (the SM473 lesson: `prove -l` puts lib/ on @INC and a real install does not) and
# the require is eval-guarded, the SM425 posture: a missing lib costs the
# operator a syslog copy, never a submission - STDERR has the line either way.
sub _forward_diag {
    my ( $level, $line ) = @_;
    my %prio = ( DEBUG => 'debug', INFO => 'info', WARN => 'warning', ERROR => 'err' );
    eval {
        require Lazysite::Util;
        Lazysite::Util::forward_line( 'diag', $prio{$level} // 'info', $line );
        1;
    };
    return;
}

sub _json_str {
    my ($s) = @_;
    $s //= '';
    $s =~ s/\\/\\\\/g;
    $s =~ s/"/\\"/g;
    $s =~ s/\n/\\n/g;
    $s =~ s/\r/\\r/g;
    $s =~ s/\t/\\t/g;
    return $s;
}
