'use client';

import { useState, useMemo } from 'react';
import { Section } from '@/components/ui/Section';
import { PlaceholderState } from '@/components/ui/PlaceholderState';
import { SandboxWrapper } from '@/components/sandbox/SandboxWrapper';
import { useSlug } from '@/lib/hooks';
import { gbp } from '@/lib/format';
import {
  Search,
  ChevronDown,
  ChevronRight,
  CreditCard,
  Banknote,
  Building2,
} from 'lucide-react';

// ---- Type definitions ----

interface AccountOverviewRow {
  id: number;
  bank_name: string;
  account_name: string;
  account_type: string;
  realm: string;
  current_balance: string;
  transaction_count: number;
  earliest_tx_date: string | null;
  latest_tx_date: string | null;
}

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

// ---- Filter tabs ----

type FilterTab = 'all' | 'personal' | 'work' | 'credit_cards';

const FILTER_TABS: { key: FilterTab; label: string }[] = [
  { key: 'all', label: 'All' },
  { key: 'personal', label: 'Personal' },
  { key: 'work', label: 'Work' },
  { key: 'credit_cards', label: 'Credit Cards' },
];

// ---- Colour helpers ----

function realmBadgeColour(realm: string): string {
  switch (realm) {
    case 'personal':
    case 'owner':
      return 'text-blue-700 bg-blue-100';
    case 'work':
      return 'text-amber-700 bg-amber-100';
    default:
      return 'text-ink-600 bg-ink-100';
  }
}

// ---- Expanded transaction row ----

function ExpandedTransactions({
  accountName,
}: {
  accountName: string;
}) {
  const transactions = useSlug<BankTxRow>(
    'personal_bank_transactions',
    { limit: 200 },
    { refetchInterval: 5 * 60_000 }
  );

  const accountTxs = useMemo(() => {
    if (!transactions.data) return [];
    return transactions.data
      .filter((tx) => tx.account_name === accountName)
      .slice(0, 10);
  }, [transactions.data, accountName]);

  if (transactions.isLoading) {
    return (
      <div className="px-4 py-3 text-xs text-ink-500">
        Loading transactions...
      </div>
    );
  }

  if (accountTxs.length === 0) {
    return (
      <div className="px-4 py-3 text-xs text-ink-500">
        No recent transactions found.
      </div>
    );
  }

  return (
    <div className="overflow-x-auto">
      <table className="w-full text-xs">
        <thead className="text-ink-500 uppercase tracking-wider">
          <tr className="border-b border-ink-200">
            <th className="px-3 py-1.5 text-left">Date</th>
            <th className="px-3 py-1.5 text-left">Description</th>
            <th className="px-3 py-1.5 text-right">Amount</th>
            <th className="px-3 py-1.5 text-right">Balance</th>
            <th className="px-3 py-1.5 text-left">Category</th>
          </tr>
        </thead>
        <tbody>
          {accountTxs.map((tx) => {
            const amt = parseFloat(tx.amount || '0');
            const isCredit = amt > 0;
            return (
              <tr key={tx.id} className="border-t border-ink-100 hover:bg-ink-50">
                <td className="px-3 py-1.5 whitespace-nowrap text-ink-700">
                  {tx.transaction_date
                    ? new Date(tx.transaction_date).toLocaleDateString('en-GB', {
                        day: '2-digit',
                        month: 'short',
                        year: '2-digit',
                      })
                    : '-'}
                </td>
                <td className="px-3 py-1.5 text-ink-700 max-w-xs truncate" title={tx.description}>
                  {tx.description}
                </td>
                <td
                  className={`px-3 py-1.5 text-right font-mono whitespace-nowrap ${
                    isCredit ? 'text-good' : 'text-warn'
                  }`}
                >
                  {isCredit ? '+' : ''}
                  {gbp(amt, 2)}
                </td>
                <td className="px-3 py-1.5 text-right font-mono text-ink-600 whitespace-nowrap">
                  {tx.balance != null ? gbp(parseFloat(tx.balance), 2) : '-'}
                </td>
                <td className="px-3 py-1.5">
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
  );
}

// ---- Main page ----

export default function AccountsPage() {
  const accounts = useSlug<AccountOverviewRow>('accounts_overview', {}, {
    refetchInterval: 5 * 60_000,
  });

  const [search, setSearch] = useState('');
  const [filterTab, setFilterTab] = useState<FilterTab>('all');
  const [expandedId, setExpandedId] = useState<number | null>(null);

  // Filter and search
  const filtered = useMemo(() => {
    if (!accounts.data) return [];
    let list = accounts.data;

    // Tab filter
    if (filterTab === 'personal') {
      list = list.filter((a) => a.realm === 'personal' || a.realm === 'owner');
    } else if (filterTab === 'work') {
      list = list.filter((a) => a.realm === 'work');
    } else if (filterTab === 'credit_cards') {
      list = list.filter((a) => a.account_type === 'credit_card');
    }

    // Search
    if (search.trim()) {
      const q = search.toLowerCase();
      list = list.filter(
        (a) =>
          a.account_name.toLowerCase().includes(q) ||
          a.bank_name.toLowerCase().includes(q) ||
          a.realm.toLowerCase().includes(q) ||
          a.account_type.toLowerCase().includes(q)
      );
    }

    return list;
  }, [accounts.data, filterTab, search]);

  // Totals
  const totalBalance = useMemo(() => {
    return filtered.reduce((sum, a) => sum + parseFloat(a.current_balance || '0'), 0);
  }, [filtered]);

  const totalTransactions = useMemo(() => {
    return filtered.reduce((sum, a) => sum + (a.transaction_count || 0), 0);
  }, [filtered]);

  return (
    <div className="space-y-6">
      <SandboxWrapper id="personal.accounts-overview" label="Accounts overview">
        <Section
          title={`Accounts overview (${filtered.length})`}
          action={
            <div className="flex items-center gap-2">
              <div className="relative">
                <Search className="absolute left-2.5 top-1/2 -translate-y-1/2 w-3.5 h-3.5 text-ink-400" />
                <input
                  type="text"
                  placeholder="Search accounts..."
                  value={search}
                  onChange={(e) => setSearch(e.target.value)}
                  className="pl-8 pr-3 py-1.5 text-xs rounded-md border border-ink-200 bg-ink-0 text-ink-800 placeholder:text-ink-400 focus:outline-none focus:border-amber-500 w-48"
                />
              </div>
            </div>
          }
        >
          {/* Filter tabs */}
          <div className="flex gap-1 mb-3 flex-wrap">
            {FILTER_TABS.map((tab) => (
              <button
                key={tab.key}
                onClick={() => {
                  setFilterTab(tab.key);
                  setExpandedId(null);
                }}
                className={`px-3 py-1.5 text-xs rounded-md font-medium transition-colors ${
                  filterTab === tab.key
                    ? 'bg-amber-500 text-white'
                    : 'bg-ink-100 text-ink-600 hover:bg-ink-200'
                }`}
              >
                {tab.label}
              </button>
            ))}
          </div>

          {accounts.isLoading ? (
            <PlaceholderState message="Loading accounts..." />
          ) : filtered.length === 0 ? (
            <PlaceholderState
              message="No accounts found."
              hint={search ? 'Try adjusting your search criteria.' : 'No accounts match the selected filter.'}
            />
          ) : (
            <>
              {/* Summary bar */}
              <div className="grid grid-cols-2 sm:grid-cols-4 gap-3 mb-3">
                <div className="tile p-3">
                  <div className="text-xs text-ink-500 uppercase tracking-wider">
                    Accounts
                  </div>
                  <div className="text-lg font-mono font-semibold text-ink-900 mt-1">
                    {filtered.length}
                  </div>
                </div>
                <div className="tile p-3">
                  <div className="text-xs text-ink-500 uppercase tracking-wider">
                    Total balance
                  </div>
                  <div
                    className={`text-lg font-mono font-semibold mt-1 ${
                      totalBalance >= 0 ? 'text-good' : 'text-warn'
                    }`}
                  >
                    {gbp(totalBalance, 0)}
                  </div>
                </div>
                <div className="tile p-3">
                  <div className="text-xs text-ink-500 uppercase tracking-wider">
                    Transactions
                  </div>
                  <div className="text-lg font-mono font-semibold text-ink-900 mt-1">
                    {totalTransactions.toLocaleString()}
                  </div>
                </div>
                <div className="tile p-3">
                  <div className="text-xs text-ink-500 uppercase tracking-wider">
                    Filter
                  </div>
                  <div className="text-lg font-mono font-semibold text-ink-900 mt-1 capitalize">
                    {filterTab === 'credit_cards' ? 'Credit cards' : filterTab}
                  </div>
                </div>
              </div>

              {/* Accounts table */}
              <div className="tile overflow-x-auto">
                <table className="w-full text-sm">
                  <thead className="text-ink-500 uppercase tracking-wider text-xs sticky top-0 bg-ink-0">
                    <tr className="border-b border-ink-200">
                      <th className="px-3 py-2 text-left w-8"></th>
                      <th className="px-3 py-2 text-left">Account</th>
                      <th className="px-3 py-2 text-left hidden sm:table-cell">Bank</th>
                      <th className="px-3 py-2 text-left hidden md:table-cell">Type</th>
                      <th className="px-3 py-2 text-right">Balance</th>
                      <th className="px-3 py-2 text-right hidden sm:table-cell">Tx count</th>
                      <th className="px-3 py-2 text-left hidden lg:table-cell">Date range</th>
                      <th className="px-3 py-2 text-left hidden md:table-cell">Realm</th>
                    </tr>
                  </thead>
                  <tbody>
                    {filtered.map((a) => {
                      const bal = parseFloat(a.current_balance || '0');
                      const balClass =
                        a.account_type === 'credit_card'
                          ? 'text-red-500'
                          : bal >= 0
                          ? 'text-good'
                          : 'text-warn';
                      const isExpanded = expandedId === a.id;
                      const rowBorder =
                        a.realm === 'personal' || a.realm === 'owner'
                          ? 'border-l-2 border-l-blue-500'
                          : a.realm === 'work'
                          ? 'border-l-2 border-l-amber-500'
                          : '';
                      const isCC = a.account_type === 'credit_card';

                      return (
                        <>
                          <tr
                            key={a.id}
                            className={`border-b border-ink-100 hover:bg-ink-50 cursor-pointer transition-colors ${rowBorder} ${
                              isCC ? 'bg-red-50/30' : ''
                            } ${isExpanded ? 'bg-ink-50' : ''}`}
                            onClick={() =>
                              setExpandedId(isExpanded ? null : a.id)
                            }
                          >
                            <td className="px-3 py-2.5 text-ink-400">
                              {isExpanded ? (
                                <ChevronDown className="w-4 h-4" />
                              ) : (
                                <ChevronRight className="w-4 h-4" />
                              )}
                            </td>
                            <td className="px-3 py-2.5">
                              <div className="flex items-center gap-2">
                                {isCC ? (
                                  <CreditCard size={16} className="text-red-500 shrink-0" />
                                ) : (
                                  <Banknote size={16} className="text-ink-400 shrink-0" />
                                )}
                                <div>
                                  <div className="font-medium text-ink-900">
                                    {a.account_name}
                                  </div>
                                  <div className="text-xs text-ink-500 sm:hidden">
                                    {a.bank_name} · {a.account_type.replace(/_/g, ' ')}
                                  </div>
                                </div>
                              </div>
                            </td>
                            <td className="px-3 py-2.5 text-ink-600 hidden sm:table-cell">
                              {a.bank_name}
                            </td>
                            <td className="px-3 py-2.5 hidden md:table-cell">
                              <span className="px-1.5 py-0.5 rounded text-xs bg-ink-100 text-ink-600 capitalize">
                                {a.account_type.replace(/_/g, ' ')}
                              </span>
                            </td>
                            <td
                              className={`px-3 py-2.5 text-right font-mono font-semibold whitespace-nowrap ${balClass}`}
                            >
                              {gbp(isCC ? Math.abs(bal) : bal, 0)}
                            </td>
                            <td className="px-3 py-2.5 text-right font-mono text-ink-600 hidden sm:table-cell">
                              {a.transaction_count.toLocaleString()}
                            </td>
                            <td className="px-3 py-2.5 text-xs text-ink-500 hidden lg:table-cell whitespace-nowrap">
                              {a.earliest_tx_date && a.latest_tx_date
                                ? `${new Date(a.earliest_tx_date).toLocaleDateString('en-GB', { day: 'numeric', month: 'short', year: '2-digit' })} — ${new Date(a.latest_tx_date).toLocaleDateString('en-GB', { day: 'numeric', month: 'short', year: '2-digit' })}`
                                : a.latest_tx_date
                                ? `— ${new Date(a.latest_tx_date).toLocaleDateString('en-GB', { day: 'numeric', month: 'short', year: '2-digit' })}`
                                : '-'}
                            </td>
                            <td className="px-3 py-2.5 hidden md:table-cell">
                              <span
                                className={`px-1.5 py-0.5 rounded text-2xs font-medium capitalize ${realmBadgeColour(a.realm)}`}
                              >
                                {a.realm === 'owner' ? 'personal' : a.realm}
                              </span>
                            </td>
                          </tr>
                          {/* Expanded transaction row */}
                          {isExpanded && (
                            <tr key={`expanded-${a.id}`}>
                              <td
                                colSpan={8}
                                className="bg-ink-50/70 border-b border-ink-200 px-4 py-3"
                              >
                                <div className="text-xs text-ink-500 uppercase tracking-wider mb-2">
                                  Recent transactions — {a.account_name}
                                </div>
                                <ExpandedTransactions accountName={a.account_name} />
                              </td>
                            </tr>
                          )}
                        </>
                      );
                    })}
                  </tbody>
                </table>
              </div>
            </>
          )}
        </Section>
      </SandboxWrapper>
    </div>
  );
}
