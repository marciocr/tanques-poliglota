var
  G: TGame;
  F: TextFile;
  Line, Ks, Tok: string;
  Keys: array[0..511] of Byte;
  Steps, I, P, Code: Integer;
begin
  { Driver de teste (Pascal): o programa foi cortado antes do bloco principal. }
  SetExceptionMask([exInvalidOp, exDenormalized, exZeroDivide, exOverflow, exUnderflow, exPrecision]);
  G := TGame.Create;
  AssignFile(F, ParamStr(1));
  Reset(F);
  while not EOF(F) do
  begin
    ReadLn(F, Line);
    P := Pos(' ', Line);
    Val(Copy(Line, 1, P - 1), Steps, Code);
    Ks := Copy(Line, P + 1, MaxInt) + ',';
    FillChar(Keys, SizeOf(Keys), 0);
    if Ks <> '-,' then
      while Ks <> '' do
      begin
        P := Pos(',', Ks);
        Tok := Copy(Ks, 1, P - 1);
        Delete(Ks, 1, P);
        Keys[StrToInt(Tok)] := 1;
      end;
    for I := 1 to Steps do G.Update(@Keys[0], STEP);
  end;
  for I := 0 to 1 do
    with G.Tanks[I] do
      WriteLn(Format('x=%.4f y=%.4f dir=%d score=%d spin=%.4f bullet=%d', [X, Y, Dir, Score, Spin, Ord(Bullet.Active)]));
  WriteLn(Format('mode=%d time=%.4f', [G.Mode, G.TimeLeft]));
end.
