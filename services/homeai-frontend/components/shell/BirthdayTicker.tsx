'use client';

import { useSlug } from '@/lib/hooks';

interface BirthdayRow {
  external_id: number;
  full_name: string;
  dob: string;
  next_bday: string;
  age_then: number;
}

function isBirthdayToday(dob: string): boolean {
  if (!dob) return false;
  const today = new Date();
  const bday = new Date(dob);
  return bday.getMonth() === today.getMonth() && bday.getDate() === today.getDate();
}

export function BirthdayTicker() {
  const birthdays = useSlug<BirthdayRow>('staff_birthdays_next_30d', {}, { refetchInterval: 60_000 });

  const todayBirthdays = (birthdays.data ?? []).filter((b) => isBirthdayToday(b.dob));

  if (todayBirthdays.length === 0) return null;

  return (
    <div className="border-t border-ink-200 bg-amber-500/10 px-3 py-2">
      <div className="flex items-center gap-1.5 text-2xs">
        <span className="text-amber-500">🎂</span>
        <span className="text-ink-600">
          {todayBirthdays.length === 1
            ? `${todayBirthdays[0].full_name}&apos;s birthday today!`
            : `${todayBirthdays.map((b) => b.full_name).join(', ')} — birthdays today!`}
        </span>
      </div>
    </div>
  );
}
