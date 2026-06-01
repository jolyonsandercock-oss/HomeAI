'use client';

import { Section } from '@/components/ui/Section';
import { KPICard } from '@/components/ui/KPICard';
import { PlaceholderState } from '@/components/ui/PlaceholderState';
import { SandboxWrapper } from '@/components/sandbox/SandboxWrapper';
import { useSlug } from '@/lib/hooks';
import { gbp } from '@/lib/format';
import { TrendingUp, CreditCard, Building2, Banknote } from 'lucide-react';

interface NetWorthRow {
  property_value: string;
  net_cash: string;
  secured_borrowing: string;
  unsecured_borrowing: string;
  total_assets: string;
  total_borrowing: string;
  net_worth: string;
}
interface AccountBalanceRow {
  id: number;
  entity_name: string;
  realm: string;
  bank_name: string;
  account_name: string;
  account_number: string;
  account_type: string;
  balance: string;
  as_of_date: string;
  is_liability: boolean;
}
interface CreditCardRow {
  account_name: string;
  statement_date: string;
  opening_balance: string;
  payments_credited: string;
  spending_charged: string;
  closing_balance: string;
  min_payment: string;
  min_payment_due_date: string;
  credit_limit: string;
}
interface MortgageRow {
  lender: string;
  account_ref: string;
  borrower: string;
  product_type: string;
  current_balance: string;
  balance_as_of: string;
  monthly_payment: string;
  interest_rate_pct: string;
  secured_against: string;
  document_count: number;
}
interface RentalIncomeRow { tenant_name: string; mortgage_ref: string; mortgage_label: string; mortgage_payment: string | number; expected_monthly: string | number; last_payment_date: string | null; last_payment_amount: string | number | null; avg_monthly_amount: string | number; payment_status: string; }

interface BankTxRow {
  id: number;
  transaction_date: string;
  account_name: string;
  bank_name: string;
  description: string;
  amount: string;
  balance: string;
  category: string;
  account_type: string;
}

export default function PersonalPage() {
  const netWorth = useSlug<NetWorthRow>('net_worth_summary', {}, { refetchInterval: 5 * 60_000 });
  const accounts = useSlug<AccountBalanceRow>('account_balances', {}, { refetchInterval: 5 * 60_000 });
  const creditCards = useSlug<CreditCardRow>('credit_card_status', {}, { refetchInterval: 5 * 60_000 });
  const mortgages = useSlug<MortgageRow>('mortgages_summary', {}, { refetchInterval: 10 * 60_000 });
  const transactions = useSlug<BankTxRow>('personal_bank_transactions', { limit: 50 }, { refetchInterval: 5 * 60_000 });
  const rental = useSlug<RentalIncomeRow>('rental_income', {}, { refetchInterval: 10 * 60_000 });
  const personalLoans = useSlug<any>('personal_loans', {}, { refetchInterval: 10 * 60_000 });

  const nw = netWorth.data?.[0];
  const netWorthNum = nw ? parseFloat(nw.net_worth) : null;

  const personalAccounts = (accounts.data ?? []).filter(
    (a) => a.realm === 'personal' || a.realm === 'owner'
  );

  const depositAccounts = personalAccounts.filter(
    (a) => a.account_type === 'current' || a.account_type === 'savings' || a.account_type === 'joint'
  );
  const creditCardAccounts = personalAccounts.filter(
    (a) => a.account_type === 'credit_card'
  );

  const totalDepositBalance = depositAccounts.reduce(
    (sum, a) => sum + parseFloat(a.balance || '0'), 0
  );

  return (
    <div className="space-y-6">
      <SandboxWrapper id="personal.net-worth" label="Net worth">
        <Section title="Net worth">
          {netWorth.isLoading ? <PlaceholderState message="Loading..." /> : nw ? (
            <div className="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-4 gap-3">
              <KPICard
                label="Net worth"
                value={netWorthNum != null ? gbp(netWorthNum) : '-'}
              />
              <KPICard
                label="Total assets"
                value={gbp(parseFloat(nw.total_assets))}
              />
              <KPICard
                label="Net cash"
                value={gbp(parseFloat(nw.net_cash))}
              />
              <KPICard
                label="Total borrowing"
                value={gbp(parseFloat(nw.total_borrowing))}
              />
            </div>
          ) : (
            <PlaceholderState message="No net worth data." hint="Calculated from property value, cash, and borrowing." />
          )}
        </Section>
        {nw && (
          <div className="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-4 gap-3 mt-0">
            <div className="tile p-3">
              <div className="text-xs text-ink-500 uppercase tracking-wider">Property value</div>
              <div className="text-lg font-mono font-semibold text-ink-900 mt-1">{gbp(parseFloat(nw.property_value))}</div>
            </div>
            <div className="tile p-3">
              <div className="text-xs text-ink-500 uppercase tracking-wider">Secured borrowing</div>
              <div className="text-lg font-mono font-semibold text-warn mt-1">{gbp(parseFloat(nw.secured_borrowing))}</div>
            </div>
            <div className="tile p-3">
              <div className="text-xs text-ink-500 uppercase tracking-wider">Unsecured borrowing</div>
              <div className="text-lg font-mono font-semibold text-warn mt-1">{gbp(parseFloat(nw.unsecured_borrowing))}</div>
            </div>
            <div className="tile p-3">
              <div className="text-xs text-ink-500 uppercase tracking-wider">Net cash</div>
              <div className="text-lg font-mono font-semibold text-ink-900 mt-1">{gbp(parseFloat(nw.net_cash))}</div>
            </div>
          </div>
        )}
      </SandboxWrapper>

      <SandboxWrapper id="personal.banking" label="Banking">
        <Section title={`Banking — deposit accounts (${depositAccounts.length})`}>
          {accounts.isLoading ? <PlaceholderState message="Loading..." /> :
           depositAccounts.length > 0 ? (
            <>
              <div className="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-3 gap-3 mb-3">
                {depositAccounts.map((a) => {
                  const bal = parseFloat(a.balance || '0');
                  const balClass = bal >= 0 ? 'text-good' : 'text-warn';
                  return (
                    <div key={a.id} className="tile p-3">
                      <div className="flex items-center justify-between">
                        <div>
                          <div className="text-sm font-medium text-ink-900">{a.account_name}</div>
                          <div className="text-xs text-ink-500">{a.bank_name} . {a.account_type}</div>
                        </div>
                        <Banknote size={18} className="text-ink-400" />
                      </div>
                      <div className={`text-xl font-mono font-semibold mt-2 ${balClass}`}>
                        {gbp(bal)}
                      </div>
                      <div className="text-xs text-ink-500 mt-0.5">
                        {a.account_number ? `...${a.account_number.slice(-4)}` : ''}
                      </div>
                    </div>
                  );
                })}
              </div>
              <div className="tile p-3">
                <div className="flex items-center justify-between">
                  <div className="text-xs text-ink-500 uppercase tracking-wider">Total deposit balance</div>
                  <div className={`text-lg font-mono font-semibold ${totalDepositBalance >= 0 ? 'text-good' : 'text-warn'}`}>
                    {gbp(totalDepositBalance)}
                  </div>
                </div>
              </div>
            </>
          ) : (
            <PlaceholderState message="No personal banking accounts." hint="Bank accounts are configured in the admin section." />
          )}
        </Section>
      </SandboxWrapper>

      <SandboxWrapper id="personal.credit-cards" label="Credit cards">
        <Section title={`Credit cards (${creditCardAccounts.length + (creditCards.data?.length ?? 0)})`}>
          {accounts.isLoading && creditCards.isLoading ? <PlaceholderState message="Loading..." /> : (
            <>
              {(creditCards.data ?? []).length > 0 ? (
                <div className="grid grid-cols-1 sm:grid-cols-2 gap-3 mb-3">
                  {(creditCards.data ?? []).map((cc, i) => {
                    const closing = parseFloat(cc.closing_balance || '0');
                    const limit = parseFloat(cc.credit_limit || '0');
                    const utilPct = limit > 0 ? (closing / limit * 100) : 0;
                    const utilClass = utilPct > 75 ? 'text-warn' : utilPct > 50 ? 'text-amber-500' : 'text-good';
                    return (
                      <div key={i} className="tile p-3">
                        <div className="flex items-center justify-between">
                          <div>
                            <div className="text-sm font-medium text-ink-900">{cc.account_name}</div>
                            <div className="text-xs text-ink-500">Statement: {cc.statement_date}</div>
                          </div>
                          <CreditCard size={18} className="text-ink-400" />
                        </div>
                        <div className="grid grid-cols-2 gap-2 mt-3">
                          <div>
                            <div className="text-xs text-ink-500">Balance</div>
                            <div className="text-lg font-mono font-semibold text-warn">{gbp(closing)}</div>
                          </div>
                          <div>
                            <div className="text-xs text-ink-500">Limit</div>
                            <div className="text-lg font-mono font-semibold text-ink-900">{gbp(limit)}</div>
                          </div>
                          <div>
                            <div className="text-xs text-ink-500">Spending</div>
                            <div className="text-sm font-mono text-ink-700">{gbp(parseFloat(cc.spending_charged || '0'))}</div>
                          </div>
                          <div>
                            <div className="text-xs text-ink-500">Utilisation</div>
                            <div className={`text-sm font-mono font-semibold ${utilClass}`}>{utilPct.toFixed(1)}%</div>
                          </div>
                        </div>
                        {cc.min_payment_due_date && (
                          <div className="text-xs text-ink-500 mt-2">
                            Min payment: {gbp(parseFloat(cc.min_payment || '0'))} due {cc.min_payment_due_date}
                          </div>
                        )}
                      </div>
                    );
                  })}
                </div>
              ) : null}

              {creditCardAccounts.length > 0 ? (
                <div className="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-3 gap-3">
                  {creditCardAccounts.map((a) => {
                    const bal = parseFloat(a.balance || '0');
                    return (
                      <div key={a.id} className="tile p-3">
                        <div className="flex items-center justify-between">
                          <div>
                            <div className="text-sm font-medium text-ink-900">{a.account_name}</div>
                            <div className="text-xs text-ink-500">{a.bank_name} . credit card</div>
                          </div>
                          <CreditCard size={18} className="text-ink-400" />
                        </div>
                        <div className="text-xl font-mono font-semibold mt-2 text-warn">
                          {gbp(Math.abs(bal))}
                        </div>
                        <div className="text-xs text-ink-500 mt-0.5">outstanding</div>
                      </div>
                    );
                  })}
                </div>
              ) : !(creditCards.data ?? []).length ? (
                <PlaceholderState message="No credit card accounts or statements." />
              ) : null}
            </>
          )}
        </Section>
      </SandboxWrapper>

      <SandboxWrapper id="personal.mortgage" label="Mortgage">
        <Section title={`Mortgage${(mortgages.data?.length ?? 0) !== 1 ? 's' : ''} (${mortgages.data?.length ?? 0})`}>
          {mortgages.isLoading ? <PlaceholderState message="Loading..." /> :
           mortgages.data && mortgages.data.length > 0 ? (
            <div className="grid grid-cols-1 sm:grid-cols-2 gap-3">
              {mortgages.data.map((m, i) => {
                const bal = parseFloat(m.current_balance || '0');
                return (
                  <div key={i} className="tile p-3">
                    <div className="flex items-center justify-between">
                      <div>
                        <div className="text-sm font-medium text-ink-900">{m.lender}</div>
                        <div className="text-xs text-ink-500">{m.product_type} . {m.account_ref}</div>
                      </div>
                      <Building2 size={18} className="text-ink-400" />
                    </div>
                    <div className="grid grid-cols-2 gap-2 mt-3">
                      <div>
                        <div className="text-xs text-ink-500">Balance</div>
                        <div className="text-lg font-mono font-semibold text-warn">{gbp(bal)}</div>
                      </div>
                      <div>
                        <div className="text-xs text-ink-500">Rate</div>
                        <div className="text-lg font-mono font-semibold text-ink-900">{parseFloat(m.interest_rate_pct).toFixed(2)}%</div>
                      </div>
                      <div>
                        <div className="text-xs text-ink-500">Monthly payment</div>
                        <div className="text-sm font-mono text-ink-700">{gbp(parseFloat(m.monthly_payment || '0'))}</div>
                      </div>
                      <div>
                        <div className="text-xs text-ink-500">Secured on</div>
                        <div className="text-sm font-mono text-ink-700">{m.secured_against || '-'}</div>
                      </div>
                    </div>
                    <div className="text-xs text-ink-500 mt-2">
                      Balance as of: {m.balance_as_of} . {m.borrower} . {m.document_count} docs
                    </div>
                  </div>
                );
              })}
            </div>
          ) : (
            <PlaceholderState message="No mortgage accounts." hint="Mortgage data is tracked in the mortgage_accounts table." />
          )}
        </Section>
      </SandboxWrapper>

      <SandboxWrapper id="personal.loans" label="Personal loans">
        <Section title="Personal loans">
          {personalLoans.isLoading ? <PlaceholderState message="Loading..." /> :
           personalLoans.data && personalLoans.data.length > 0 ? (
            <div className="grid grid-cols-1 sm:grid-cols-2 gap-3">
              {personalLoans.data.map((l: any, i: number) => (
                <div key={i} className="tile p-3">
                  <div className="text-xs text-ink-500 uppercase">{l.lender}</div>
                  <div className="text-sm text-ink-700 mt-0.5">{l.account_name}</div>
                  <div className="mt-2 grid grid-cols-3 gap-2 text-xs">
                    <div><span className="text-ink-500">Original</span><br/><span className="text-ink-800 font-mono">{Number(l.original_balance).toLocaleString()}</span></div>
                    <div><span className="text-ink-500">Remaining</span><br/><span className="text-warn font-mono">{Number(l.current_balance).toLocaleString()}</span></div>
                    <div><span className="text-ink-500">Repaid</span><br/><span className="text-good font-mono">{(Number(l.original_balance) - Number(l.current_balance)).toLocaleString()}</span></div>
                  </div>
                </div>
              ))}
            </div>
          ) : <PlaceholderState message="No personal loans." />}
        </Section>
      </SandboxWrapper>

      <SandboxWrapper id="personal.rental-income" label="Rental income">
        <Section title="Rental income vs mortgage payments">
          {rental.isLoading ? <PlaceholderState message="Loading..." /> :
           rental.data && rental.data.length > 0 ? (
            <div className="space-y-4">
              {(() => {
                const byMortgage = {} as Record<string, any[]>;
                (rental.data ?? []).forEach((r) => {
                  if (!byMortgage[r.mortgage_label]) byMortgage[r.mortgage_label] = [];
                  byMortgage[r.mortgage_label].push(r);
                });
                return Object.entries(byMortgage).map(([label, tenants], gi) => {
                  const totalRent = tenants.reduce((s, t) => s + Number(t.expected_monthly ?? 0), 0);
                  const mortgage = Number(tenants[0]?.mortgage_payment ?? 0);
                  const headroom = totalRent - mortgage;
                  const statusCls = (s: string) => s === 'paid' ? 'text-good' : s === 'late' ? 'text-amber-400' : 'text-warn';
                  return (
                    <div key={gi} className="tile p-2">
                      <div className="flex justify-between items-center mb-2">
                        <div className="text-xs text-ink-500 uppercase tracking-wider">{label}</div>
                        <div className="text-xs text-ink-600">
                          Rent roll <span className="text-ink-800 font-mono">{totalRent.toLocaleString()}</span>
                          {' vs mortgage '}<span className="text-ink-800 font-mono">{mortgage.toLocaleString()}</span>
                          {' = '}<span className={headroom >= 0 ? 'text-good font-mono' : 'text-warn font-mono'}>{(headroom >= 0 ? '+' : '')}{headroom.toLocaleString()}</span>/m
                        </div>
                      </div>
                      <table className="w-full text-xs">
                        <thead className="text-ink-500">
                          <tr>
                            <th className="text-left py-0.5">Tenant</th>
                            <th className="text-right">Expected</th>
                            <th className="text-right">Last payment</th>
                            <th className="text-right">Date</th>
                            <th className="text-right">Status</th>
                          </tr>
                        </thead>
                        <tbody>
                          {tenants.map((t, i) => (
                            <tr key={i} className="border-t border-ink-200">
                              <td className="py-0.5 text-ink-700">{t.tenant_name}</td>
                              <td className="text-right font-mono text-ink-500">{Number(t.expected_monthly).toLocaleString()}</td>
                              <td className="text-right font-mono text-ink-600">{t.last_payment_amount ? Number(t.last_payment_amount).toLocaleString() : '–'}</td>
                              <td className="text-right text-ink-500">{t.last_payment_date ? new Date(t.last_payment_date).toLocaleDateString('en-GB', {day:'numeric', month:'short'}) : '–'}</td>
                              <td className="text-right"><span className={statusCls(t.payment_status)}>{t.payment_status}</span></td>
                            </tr>
                          ))}
                        </tbody>
                      </table>
                    </div>
                  );
                });
              })()}
            </div>
          ) : <PlaceholderState message="No rental income data." />}
        </Section>
      </SandboxWrapper>

      <SandboxWrapper id="personal.transactions" label="Recent transactions">
        <Section title={`Recent transactions — last 30 days (${transactions.data?.length ?? 0})`}>
          {transactions.isLoading ? <PlaceholderState message="Loading..." /> :
           transactions.data && transactions.data.length > 0 ? (
            <div className="tile overflow-x-auto">
              <table className="w-full text-xs">
                <thead className="text-ink-500 uppercase tracking-wider text-xs sticky top-0 bg-ink-50">
                  <tr>
                    <th className="px-2 py-1.5 text-left">Date</th>
                    <th className="px-2 py-1.5 text-left">Account</th>
                    <th className="px-2 py-1.5 text-left">Description</th>
                    <th className="px-2 py-1.5 text-right">Amount</th>
                    <th className="px-2 py-1.5 text-right">Balance</th>
                    <th className="px-2 py-1.5 text-left">Category</th>
                  </tr>
                </thead>
                <tbody>
                  {transactions.data.map((tx) => {
                    const amt = parseFloat(tx.amount || '0');
                    const isCredit = amt > 0;
                    return (
                      <tr key={tx.id} className="border-t border-ink-200">
                        <td className="px-2 py-1.5 whitespace-nowrap text-ink-700">
                          {tx.transaction_date ? new Date(tx.transaction_date).toLocaleDateString('en-GB', { day: '2-digit', month: 'short' }) : '-'}
                        </td>
                        <td className="px-2 py-1.5">
                          <div className="text-ink-800">{tx.account_name}</div>
                          <div className="text-ink-500 text-2xs">{tx.bank_name}</div>
                        </td>
                        <td className="px-2 py-1.5 text-ink-700 max-w-xs truncate" title={tx.description}>
                          {tx.description}
                        </td>
                        <td className={`px-2 py-1.5 text-right font-mono whitespace-nowrap ${isCredit ? 'text-good' : 'text-warn'}`}>
                          {isCredit ? '+' : ''}{gbp(amt)}
                        </td>
                        <td className="px-2 py-1.5 text-right font-mono text-ink-700 whitespace-nowrap">
                          {tx.balance != null ? gbp(parseFloat(tx.balance)) : '-'}
                        </td>
                        <td className="px-2 py-1.5">
                          {tx.category ? (
                            <span className="px-1.5 py-0.5 rounded text-2xs bg-ink-100 text-ink-600">
                              {tx.category.replace(/_/g, ' ')}
                            </span>
                          ) : (
                            <span className="text-ink-400">-</span>
                          )}
                        </td>
                      </tr>
                    );
                  })}
                </tbody>
              </table>
            </div>
          ) : (
            <PlaceholderState message="No recent transactions." hint="Transactions are imported from bank statements." />
          )}
        </Section>
      </SandboxWrapper>
    </div>
  );
}
