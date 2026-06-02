'use client';

import { useState, useEffect, Suspense } from 'react';
import { useSearchParams } from 'next/navigation';
import { Section } from '@/components/ui/Section';

const HOT_DRINKS = [
  'Tea',
  'Coffee',
  'Decaf Coffee',
  'Herbal Tea',
  'Hot Chocolate',
  'None',
] as const;

const DISHES = [
  { value: 'Full English', label: 'Full English' },
  { value: 'Continental', label: 'Continental' },
  { value: 'Porridge', label: 'Porridge' },
  { value: 'Cereal', label: 'Cereal' },
  { value: 'Toast', label: 'Toast' },
] as const;

interface BreakfastStatus {
  valid: boolean;
  error?: string;
  already_ordered?: boolean;
  existing_order?: {
    dish: string;
    hot_drink: string;
    allergies: string;
    notes: string;
    guest_index: number;
  };
}

function BreakfastForm() {
  const sp = useSearchParams();
  const token = sp.get('stay');

  const [status, setStatus] = useState<BreakfastStatus | null>(null);
  const [loading, setLoading] = useState(true);
  const [submitting, setSubmitting] = useState(false);
  const [result, setResult] = useState<{ ok: boolean; message: string } | null>(null);

  const [guestIndex, setGuestIndex] = useState(1);
  const [hotDrink, setHotDrink] = useState('');
  const [dish, setDish] = useState('');
  const [allergies, setAllergies] = useState('');
  const [notes, setNotes] = useState('');

  useEffect(() => {
    if (!token) {
      setStatus({ valid: false, error: 'No booking token provided.' });
      setLoading(false);
      return;
    }

    fetch('/app/api/breakfast/submit?token=' + encodeURIComponent(token))
      .then(r => r.json())
      .then(data => {
        setStatus(data);
        if (data.already_ordered && data.existing_order) {
          const o = data.existing_order;
          setHotDrink(o.hot_drink || '');
          setDish(o.dish || '');
          setAllergies(o.allergies || '');
          setNotes(o.notes || '');
          if (o.guest_index) setGuestIndex(o.guest_index);
        }
        setLoading(false);
      })
      .catch(() => {
        setStatus({ valid: false, error: 'Could not verify booking token.' });
        setLoading(false);
      });
  }, [token]);

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault();
    if (!dish) return;

    setSubmitting(true);
    try {
      const r = await fetch('/app/api/breakfast/submit', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          token,
          guest_index: guestIndex,
          hot_drink: hotDrink || null,
          dish,
          allergies: allergies.trim() || null,
          notes: notes.trim() || null,
        }),
      });
      const data = await r.json();
      setResult(data);
    } catch {
      setResult({ ok: false, message: 'Network error. Please try again.' });
    } finally {
      setSubmitting(false);
    }
  };

  if (loading) {
    return (
      <div className="min-h-screen flex items-center justify-center bg-ink-50">
        <div className="text-center">
          <div className="animate-spin h-8 w-8 border-2 border-amber-500 border-t-transparent rounded-full mx-auto mb-4" />
          <p className="text-ink-600">Verifying your booking...</p>
        </div>
      </div>
    );
  }

  if (!status?.valid) {
    return (
      <div className="min-h-screen flex items-center justify-center bg-ink-50 p-4">
        <div className="max-w-md w-full bg-white border border-ink-200 rounded-lg p-6 text-center">
          <h1 className="text-lg font-mono text-warn mb-3">Invalid Link</h1>
          <p className="text-ink-600 text-sm">{status?.error || 'This breakfast link is invalid or has expired.'}</p>
          <p className="text-ink-500 text-xs mt-4">
            Please use the link from your breakfast email, or fill in the physical form in your room.
          </p>
        </div>
      </div>
    );
  }

  if (result?.ok) {
    return (
      <div className="min-h-screen flex items-center justify-center bg-ink-50 p-4">
        <div className="max-w-md w-full bg-white border border-ink-200 rounded-lg p-6 text-center">
          <h1 className="text-lg font-mono text-good mb-3">Order Confirmed!</h1>
          <p className="text-ink-600 text-sm">{result.message}</p>
          {dish && (
            <div className="mt-3 p-3 bg-ink-50 rounded text-sm text-left">
              <p><span className="text-ink-500">Dish:</span> <span className="text-ink-800 font-medium">{dish}</span></p>
              {hotDrink && <p><span className="text-ink-500">Drink:</span> <span className="text-ink-800">{hotDrink}</span></p>}
              {allergies && <p><span className="text-ink-500">Allergies:</span> <span className="text-ink-800">{allergies}</span></p>}
              {notes && <p><span className="text-ink-500">Notes:</span> <span className="text-ink-800">{notes}</span></p>}
            </div>
          )}
          <p className="text-ink-500 text-xs mt-4">
            You can revisit this link to update your order before 6am on the day.
          </p>
        </div>
      </div>
    );
  }

  return (
    <div className="min-h-screen bg-ink-50 p-4">
      <div className="max-w-md mx-auto">
        <Section title="Breakfast Pre-Order">
          <div className="text-sm text-ink-600 mb-4">
            Please select your breakfast for tomorrow morning. Orders must be in by 6am.
          </div>

          {status.already_ordered && (
            <div className="mb-4 p-2 bg-amber-50 border border-amber-200 rounded text-xs text-amber-700">
              You have already placed an order. Submitting again will update it.
            </div>
          )}

          <form onSubmit={handleSubmit} className="space-y-4">
            <div>
              <label className="block text-sm font-medium text-ink-700 mb-1.5">
                Hot Drink
              </label>
              <select
                value={hotDrink}
                onChange={e => setHotDrink(e.target.value)}
                className="w-full border border-ink-200 rounded-md px-3 py-2 text-sm bg-white focus:ring-1 focus:ring-amber-500 focus:border-amber-500"
              >
                <option value="">— Select a drink —</option>
                {HOT_DRINKS.map(d => (
                  <option key={d} value={d}>{d}</option>
                ))}
              </select>
            </div>

            <div>
              <label className="block text-sm font-medium text-ink-700 mb-1.5">
                Dish <span className="text-warn">*</span>
              </label>
              <div className="space-y-2">
                {DISHES.map(d => (
                  <label key={d.value} className="flex items-center gap-2 p-2 border border-ink-200 rounded-md cursor-pointer hover:bg-ink-50 has-[:checked]:border-amber-500 has-[:checked]:bg-amber-50">
                    <input
                      type="radio"
                      name="dish"
                      value={d.value}
                      checked={dish === d.value}
                      onChange={e => setDish(e.target.value)}
                      className="text-amber-500 focus:ring-amber-500"
                      required
                    />
                    <span className="text-sm text-ink-800">{d.label}</span>
                  </label>
                ))}
              </div>
            </div>

            <div>
              <label className="block text-sm font-medium text-ink-700 mb-1.5">
                Allergies / Dietary Requirements
              </label>
              <input
                type="text"
                value={allergies}
                onChange={e => setAllergies(e.target.value)}
                placeholder="e.g. gluten free, nut allergy"
                className="w-full border border-ink-200 rounded-md px-3 py-2 text-sm bg-white focus:ring-1 focus:ring-amber-500 focus:border-amber-500"
              />
            </div>

            <div>
              <label className="block text-sm font-medium text-ink-700 mb-1.5">
                Additional Notes
              </label>
              <textarea
                value={notes}
                onChange={e => setNotes(e.target.value)}
                placeholder="e.g. preferred time, extra toast"
                rows={2}
                className="w-full border border-ink-200 rounded-md px-3 py-2 text-sm bg-white focus:ring-1 focus:ring-amber-500 focus:border-amber-500 resize-none"
              />
            </div>

            <button
              type="submit"
              disabled={submitting || !dish}
              className="w-full py-2.5 bg-amber-500 text-white rounded-md font-medium text-sm hover:bg-amber-600 disabled:opacity-50 disabled:cursor-not-allowed transition-colors"
            >
              {submitting ? 'Submitting...' : 'Submit Breakfast Order'}
            </button>
          </form>

          <p className="text-xs text-ink-500 mt-4 text-center">
            Prefer a physical form? One is available in your room.
          </p>
        </Section>
      </div>
    </div>
  );
}

export default function BreakfastPage() {
  return (
    <Suspense fallback={
      <div className="min-h-screen flex items-center justify-center bg-ink-50">
        <div className="animate-spin h-8 w-8 border-2 border-amber-500 border-t-transparent rounded-full" />
      </div>
    }>
      <BreakfastForm />
    </Suspense>
  );
}
