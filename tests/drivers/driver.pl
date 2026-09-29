# Driver de teste (Perl): o script foi cortado antes do SDL_Init.
new_match(1);
open my $fh, '<', $ARGV[0] or die;
while (<$fh>) {
    my ($steps, $ks) = split;
    my @keys = (0) x 512;
    $keys[$_] = 1 for $ks eq '-' ? () : split /,/, $ks;
    update(\@keys, STEP) for 1 .. $steps;
}
printf "x=%.4f y=%.4f dir=%d score=%d spin=%.4f bullet=%d\n", @{$_}{qw(x y dir score spin)}, $_->{bullet}{active} ? 1 : 0
    for @{ $g{tanks} };
printf "mode=%d time=%.4f\n", $g{mode}, $g{time_left};
