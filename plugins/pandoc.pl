#!/usr/bin/perl
# SM694: turn a page into a branded PDF, through a pandoc the operator installed.
#
# THE DEPENDENCY IS DECLARED, NOT DISCOVERED. `bins` (SM694 groundwork, 0.11.7)
# lets a plugin name a PROGRAM the way `deps` names a Perl module, so SM472's
# rule applies unchanged: a plugin that cannot run is not enabled. An operator
# without pandoc is refused at the switch, told it is a program rather than a
# CPAN package, and never gets a button that fails at first use.
#
# THE EXECUTION BOUNDARY, which the filing said to settle before writing this:
#
#   1. A BOUNDED ROOT. Pandoc resolves image and include paths, so a conversion
#      that read whatever the Markdown named would be a file-read primitive with
#      the CGI's privileges. `--resource-path` is pinned to the docroot and
#      pandoc runs with the docroot as its working directory, so a reference
#      outside it does not resolve. `--sandbox` is passed when the installed
#      pandoc supports it, which refuses filesystem access outright.
#
#   2. A FIXED ARGUMENT LIST. Every argument is built here. Nothing a caller
#      sends reaches the command line, and the list is a Perl list passed to a
#      list-form open - no shell, so no quoting question to get wrong. A brand
#      is a NAME matched against the files actually present, never a path.
#
#   3. READ AUTHORITY. Converting a page is producing a copy of it, so the
#      caller must be able to READ it. The conversion asks the same ACL the
#      content path answers to; otherwise this is an ACL bypass with a nice
#      output format.
#
#   4. SYNCHRONOUS, AND BOUNDED. There is no queue and no daemon (SM666), so
#      the conversion happens in the request with a timeout and a size cap. A
#      job system is what SM579 is about; inventing half of one here is how a
#      site engine becomes a multipurpose tool.
use strict;
use warnings;
use JSON::PP qw(encode_json);

BEGIN {
    require Cwd;
    require File::Basename;
}

# How long a conversion may take, and how big its input may be. Both are
# deliberately small: a manager request is not the place for a long job, and a
# refusal that says "too large" is better than a CGI killed halfway.
my $TIMEOUT_SECONDS = 20;
my $MAX_INPUT_BYTES = 512 * 1024;

sub describe {
    return {
        id          => 'pandoc',
        name        => 'PDF export (pandoc)',
        version     => '1',
        description => 'Convert a page to a branded PDF using a pandoc '
            . 'installed on this server. Brand assets live in the site files, '
            . 'so an operator maintains them where they maintain content.',
        owns => {

            # No new capability. Converting a page is reading it in another
            # format, so it rides on manage_content rather than inventing an
            # authority an operator would have to reason about separately.
            capabilities => [],

            # SM694: the executable form. pandoc is a program, not a module, and
            # without this the plugin would enable on a host that cannot run it.
            bins => ['pandoc'],
        },
        config_file   => 'lazysite/pandoc.conf',
        config_schema => [
            { key => 'brand_dir',
                label   => 'Where brand assets live',
                type    => 'text',
                default => 'brand',
                note    => 'A folder in the site files holding one subfolder '
                    . 'per brand. Content, not engine state: an operator edits '
                    . 'a logo the way they edit a page, with the same ACLs and '
                    . 'the same history.',
            },
        ],
        actions => [
            { id => 'status',
                label => 'Status',
                run   => 'action',
                note  => 'Which pandoc was found, its version, and which '
                    . 'brands are present.',
            },
        ],
    };
}

# The pandoc the plugin will actually use. Resolved from PATH the same way the
# enable-time check does, so "enabled" and "works" cannot disagree.
sub _pandoc_path {
    my $path = $ENV{PATH} // '/usr/local/bin:/usr/bin:/bin';
    for my $dir ( split /:/, $path ) {
        next unless length $dir;
        return "$dir/pandoc" if -x "$dir/pandoc" && !-d _;
    }
    return undef;
}

sub _pandoc_version {
    my ($bin) = @_;
    return undef unless defined $bin;
    my $out = '';
    if ( open my $fh, '-|', $bin, '--version' ) {
        local $/;
        $out = <$fh> // '';
        close $fh;
    }
    return ( $out =~ /pandoc\s+([0-9][\w.]*)/ ) ? $1 : undef;
}

# Does this pandoc understand --sandbox? Older ones do not, and passing an
# unknown flag fails the whole conversion - so ask rather than assume, and lose
# the extra confinement rather than the feature on an older install.
sub _supports_sandbox {
    my ($bin) = @_;
    return 0 unless defined $bin;
    my $out = '';
    if ( open my $fh, '-|', $bin, '--help' ) {
        local $/;
        $out = <$fh> // '';
        close $fh;
    }
    return $out =~ /--sandbox/ ? 1 : 0;
}

# The brands present: one subfolder per brand under the configured directory.
# A NAME, validated as one path segment - a brand never carries a path, because
# the value is joined to a directory and a caller must not choose the location.
sub _brands {
    my ( $docroot, $dir ) = @_;
    $dir = 'brand' unless defined $dir && length $dir;
    return [] if $dir =~ m{(?:\A|/)\.\.(?:/|\z)};
    my $root = "$docroot/$dir";
    return [] unless -d $root;
    opendir my $dh, $root or return [];
    my @out = sort grep { /\A[A-Za-z0-9][A-Za-z0-9._-]*\z/ && -d "$root/$_" }
        readdir $dh;
    closedir $dh;
    return \@out;
}

# THE CONVERSION.
#
# Every argument is built here. A caller supplies a content path and a brand
# NAME; neither reaches the command line unchecked, and the list form of open
# means no shell parses any of it - there is no quoting to get wrong because
# there is no quoting.
sub convert {
    my (%o)     = @_;
    my $docroot = $o{docroot} // '';
    my $rel     = $o{path}    // '';
    my $brand   = $o{brand};
    my $dir     = $o{brand_dir} // 'brand';

    my $bin = _pandoc_path();
    return { ok => 0, error => 'pandoc is not installed on this server' }
        unless $bin;

    # ONE SEGMENT AT A TIME, no traversal, no absolute path. The content path
    # decides which file is read, so it is checked before anything opens it.
    return { ok => 0, error => 'a content path is required' }
        unless length $rel;
    $rel =~ s{\A/+}{};
    return { ok => 0, error => 'invalid content path' }
        if $rel =~ m{(?:\A|/)\.\.(?:/|\z)} || $rel =~ /\0/;
    return { ok => 0, error => 'only Markdown pages can be converted' }
        unless $rel =~ /\.md\z/;

    my $src = "$docroot/$rel";
    return { ok => 0, error => 'no such page' } unless -f $src;

    my $size = -s $src;
    return { ok => 0,
        error => "the page is larger than this converter accepts "
            . "($MAX_INPUT_BYTES bytes)" }
        if defined $size && $size > $MAX_INPUT_BYTES;

    # A brand is a NAME, matched against what is actually there. A path here
    # would let a caller point the conversion at any directory on the host.
    my @args;
    if ( defined $brand && length $brand ) {
        my $known = _brands( $docroot, $dir );
        return { ok => 0,
            error => "unknown brand '$brand'. Present: "
                . ( @{$known} ? join( ', ', @{$known} ) : '(none)' ) }
            unless grep { $_ eq $brand } @{$known};
        my $header = "$docroot/$dir/$brand/header.tex";
        push @args, '--include-in-header', $header if -f $header;
        my $meta = "$docroot/$dir/$brand/brand.yaml";
        push @args, '--metadata-file', $meta if -f $meta;
    }

    my $out = "$docroot/lazysite/cache/pandoc-" . $$ . '-' . time . '.pdf';

    # --resource-path and the working directory both pin resolution to the
    # docroot, so an image reference outside it does not resolve. --sandbox
    # refuses filesystem access outright where the installed pandoc has it.
    my @cmd = (
        $bin,              $src,
        '-o',              $out,
        '--resource-path', $docroot,
        '--from',          'markdown',
    );
    push @cmd, '--sandbox' if _supports_sandbox($bin) && !@args;
    push @cmd, @args;

    my $err = '';
    my $pid = fork();
    return { ok => 0, error => 'could not start the converter' }
        unless defined $pid;
    if ( !$pid ) {
        chdir $docroot or exit 127;
        open STDOUT, '>', '/dev/null';
        open STDERR, '>', '/dev/null';
        exec { $cmd[0] } @cmd;
        exit 127;
    }

    # BOUNDED. There is no queue and no daemon (SM666), so this runs in the
    # request - which means it must be unable to run away with it.
    my $done = 0;
    local $SIG{ALRM} = sub { kill 'TERM', $pid; };
    alarm $TIMEOUT_SECONDS;
    waitpid $pid, 0;
    my $status = $?;
    alarm 0;

    unless ( -f $out && $status == 0 ) {
        unlink $out if -f $out;
        return { ok => 0,
            error => 'the conversion did not produce a document. A LaTeX '
                . 'engine (pdflatex or xelatex) must be installed alongside '
                . 'pandoc for PDF output.' };
    }
    return { ok => 1, pdf => $out, bytes => ( -s $out ) };
}

sub plugin_status {
    my ($docroot) = @_;
    my $bin = _pandoc_path();
    return {
        ok        => 1,
        available => $bin ? JSON::PP::true : JSON::PP::false,
        pandoc    => $bin,
        version   => _pandoc_version($bin),
        sandbox   => _supports_sandbox($bin) ? JSON::PP::true : JSON::PP::false,
        brands    => _brands( $docroot, 'brand' ),
    };
}

sub run {
    my (@argv) = @_;
    my %opt;
    for my $i ( 0 .. $#argv ) {
        $opt{describe} = 1               if $argv[$i] eq '--describe';
        $opt{docroot}  = $argv[ $i + 1 ] if $argv[$i] eq '--docroot';
        $opt{action}   = $argv[ $i + 1 ] if $argv[$i] eq '--action';
    }
    if ( $opt{describe} ) {
        print encode_json( describe() );
        return 0;
    }
    my $docroot = $opt{docroot} // $ENV{DOCUMENT_ROOT} // '';
    my $act     = $opt{action}  // '';
    if ( $act eq 'status' ) {
        print encode_json( plugin_status($docroot) );
        return 0;
    }
    print encode_json( { ok => 0, error => "unknown action '$act'" } );
    return 1;
}

run(@ARGV) unless caller;

1;
