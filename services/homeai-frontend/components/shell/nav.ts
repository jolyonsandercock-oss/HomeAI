import {
  LayoutDashboard, Receipt, FileText, Bed, UtensilsCrossed, Wine, Coffee,
  Users, User, MessageSquare, ListChecks, Wrench, Activity, Building2, CreditCard,
} from 'lucide-react';

export interface NavItem {
  href: string;
  label: string;
  icon: typeof LayoutDashboard;
  mobile: boolean;
  realm?: 'work' | 'personal';
}

export const NAV: NavItem[] = [
  { href: '/',              label: 'Dashboard',     icon: LayoutDashboard, mobile: true,  realm: 'work' },
  { href: '/sales',         label: 'Sales',         icon: Receipt,         mobile: true,  realm: 'work' },
  { href: '/invoices',      label: 'Invoices',      icon: FileText,        mobile: false, realm: 'work' },
  { href: '/rooms',         label: 'Rooms',         icon: Bed,             mobile: true,  realm: 'work' },
  { href: '/restaurant',    label: 'Restaurant',    icon: UtensilsCrossed, mobile: false, realm: 'work' },
  { href: '/bar',           label: 'Bar',           icon: Wine,            mobile: false, realm: 'work' },
  { href: '/cafe',          label: 'Cafe',          icon: Coffee,          mobile: false, realm: 'work' },
  { href: '/staff',         label: 'Staff',         icon: Users,           mobile: false, realm: 'work' },
  { href: '/comms',         label: 'Comms',         icon: MessageSquare,   mobile: true,  realm: 'work' },
  { href: '/tasks',         label: 'Tasks',         icon: ListChecks,      mobile: false, realm: 'work' },
  { href: '/admin',         label: 'Admin',         icon: Wrench,          mobile: false, realm: 'work' },
  // Personal realm items — shown at bottom in work mode, full view in personal mode
  { href: '/personal',      label: 'Personal',      icon: User,            mobile: false, realm: 'personal' },
  { href: '/backend',       label: 'Back-end',      icon: Activity,        mobile: false, realm: 'personal' },
];
