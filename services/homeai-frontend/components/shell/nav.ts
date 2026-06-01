import {
  LayoutDashboard, Receipt, FileText, Bed, UtensilsCrossed, Wine, Coffee,
  Users, User, MessageSquare, ListChecks, Wrench, Activity,
} from 'lucide-react';

export const NAV = [
  { href: '/',              label: 'Dashboard',     icon: LayoutDashboard, mobile: true },
  { href: '/sales',         label: 'Sales',         icon: Receipt,         mobile: true },
  { href: '/invoices',      label: 'Invoices',      icon: FileText,        mobile: false },
  { href: '/rooms',         label: 'Rooms',         icon: Bed,             mobile: true },
  { href: '/restaurant',    label: 'Restaurant',    icon: UtensilsCrossed, mobile: false },
  { href: '/bar',           label: 'Bar',           icon: Wine,            mobile: false },
  { href: '/cafe',          label: 'Café',          icon: Coffee,          mobile: false },
  { href: '/staff',         label: 'Staff',         icon: Users,           mobile: false },
  { href: '/personal',      label: 'Personal',      icon: User,            mobile: false },
  { href: '/comms',         label: 'Comms',         icon: MessageSquare,   mobile: true },
  { href: '/tasks',         label: 'Tasks',         icon: ListChecks,      mobile: false },
  { href: '/admin',         label: 'Admin',         icon: Wrench,          mobile: false },
  { href: '/backend',       label: 'Back-end',      icon: Activity,        mobile: false },
];
