{ Handwritten. Uses what Rún wrote out.

  What is worth looking for: none of the types here were written by a
  human. TCustomerRow, the Orders field and the functions CustomerById and
  OrderById all came out of the database while the Rún source was being
  translated. }
program RunDemo;

{$mode Delphi}{$H+}

uses
  SysUtils, Askr.Core.Arena, Askr.Core.Text,
  Askr.Urd.Driver, Askr.Urd.Sqlite,
  Shop.Gen;

var
  A: TArena;
  C: TDbConnection;
  Customers: TCustomerRowArray;
  Orders: TOrderRowArray;
  Cust: TCustomerRow;
  Word_: TOrderRow;
  Found: Boolean;
  I, J, Total: Integer;
  Sum: Currency;
begin
  A := TArena.Create;
  C := OpenDbConnection('sqlite:.build/run/shop.db');
  try
    { One generic declaration in Rún gave two typed functions here. In
      Pascal this would have needed two nearly identical functions — or a
      generic method the compiler refuses to accept. }
    Cust := CustomerById(A, C, 3, Found);
    WriteLn(Format('CustomerById(3): %s <%s>, balance %.2f',
      [Cust.Name, Cust.Email, Cust.Balance]));
    Word_ := OrderById(A, C, 3, Found);
    WriteLn(Format('OrderById(3):    amount %.2f, customer %d',
      [Word_.Amount, Word_.CustomerId]));
    Cust := CustomerById(A, C, 9999, Found);
    WriteLn('CustomerById(9999) found: ', BoolToStr(Found, True));
    WriteLn;

    { "with orders" — the relation was read from the foreign key in the
      schema, and is fetched with one extra query, not one per row. }
    Customers := ActiveCustomers(A, C, 400);
    Total := 0;
    for I := 0 to High(Customers) do
      Total := Total + Length(Customers[I].Orders);
    WriteLn(Format('ActiveCustomers(400): %d customers, %d orders eager-loaded',
      [Length(Customers), Total]));
    for I := 0 to High(Customers) do
    begin
      Sum := 0;
      for J := 0 to High(Customers[I].Orders) do
        Sum := Sum + Customers[I].Orders[J].Amount;
      WriteLn(Format('  %-12s balance %8.2f  orders %d  sum %8.2f',
        [Customers[I].Name, Customers[I].Balance,
         Length(Customers[I].Orders), Sum]));
    end;
    WriteLn;

    Customers := CustomersMissingWeight(A, C);
    WriteLn('CustomersMissingWeight (is null): ', Length(Customers));

    Customers := SearchCustomers(A, C, '%3@example.com');
    WriteLn('SearchCustomers (like):           ', Length(Customers));

    Orders := LargeOrders(A, C, 500);
    WriteLn('LargeOrders(500):                 ', Length(Orders));

    if Length(Customers) = 0 then
    begin
      WriteLn('nothing came back — something is wrong');
      Halt(1);
    end;
  finally
    C.Free;
    A.Free;
  end;
end.
