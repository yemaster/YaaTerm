use strict;
use warnings;
use utf8;
use JSON::PP qw(decode_json);
use Encode qw(decode);
binmode STDIN, ':raw';
binmode STDOUT, ':encoding(UTF-8)';
$| = 1;

sub line {
    my ($text) = @_;
    return unless defined $text && !ref $text && length $text;
    $text =~ s/[\p{Cc}\p{Bidi_Control}]/($& eq "\n" || $& eq "\t") ? $& : '�'/ge;
    print $text, (substr($text,-1) eq "\n" ? '' : "\n");
}

sub content {
    my ($parts) = @_;
    if (!ref $parts) { line($parts); return; }
    return unless ref $parts eq 'ARRAY';
    for my $part (@$parts) {
        if (!ref $part) { line($part); next; }
        next unless ref $part eq 'HASH';
        my $type=$part->{type} // '';
        if ($type eq 'text') { line($part->{text}); }
        elsif ($type eq 'tool_use') {
            my $args=$part->{input};
            my $command=ref $args eq 'HASH' ? $args->{command} : undef;
            line(defined $command && !ref $command ? "\$ $command" : $part->{name});
        }
        elsif ($type eq 'tool_result') { content($part->{content}); }
    }
}

my $last_text;
sub event {
    my ($raw)=@_;
    my $item=eval { decode_json($raw) };
    unless (ref $item eq 'HASH') { line(decode('UTF-8',$raw)); return; }
    my $type=$item->{type} // '';
    my $message=$item->{message};
    if (($type eq 'assistant' || $type eq 'user' || $type eq 'message_end') && ref $message eq 'HASH') {
        my $parts=$message->{content};
        if ($type eq 'user') {
            content([grep { ref $_ eq 'HASH' && ($_->{type}//'') eq 'tool_result' } @$parts]) if ref $parts eq 'ARRAY';
        } elsif ($type ne 'message_end' || ($message->{role}//'') eq 'assistant') {
            content($parts);
            if (ref $parts eq 'ARRAY') {
                my @texts=map { $_->{text}//'' } grep { ref $_ eq 'HASH' && ($_->{type}//'') eq 'text' } @$parts;
                $last_text=join("\n",@texts) if @texts;
            }
        }
    } elsif ($type eq 'tool_execution_start') {
        my $args=$item->{args};
        my $cmd=ref $args eq 'HASH' ? $args->{command} : undef;
        line(defined $cmd && !ref $cmd ? "\$ $cmd" : $item->{toolName});
    } elsif ($type eq 'tool_execution_end' && ref $item->{result} eq 'HASH') {
        content($item->{result}{content});
    } elsif ($type eq 'result') {
        my $result=$item->{result};
        line($result) if !defined $last_text || !defined $result || ref $result || $result ne $last_text;
        content($item->{errors}) if ref $item->{errors} eq 'ARRAY';
    } elsif ($type eq 'error') {
        my $error=$item->{error};
        line(ref $error eq 'HASH' ? $error->{message} : $error // $message);
    }
}

# Bound a partial NDJSON record, including when the provider emits binary attachments.
my ($pending,$skip)=('',0);
while (sysread(STDIN,my $block,16384)) {
    while (length $block) {
        my $end=index($block,"\n");
        my $chunk=$end<0 ? $block : substr($block,0,$end);
        if (!$skip && length($pending)+length($chunk)>262144) {
            $skip=1; $pending=''; line('（过长的事件已省略）');
        }
        $pending.=$chunk unless $skip;
        last if $end<0;
        event($pending) if !$skip && length $pending;
        $pending=''; $skip=0; substr($block,0,$end+1,'');
    }
}
event($pending) if !$skip && length $pending;
