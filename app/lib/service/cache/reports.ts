import { withError } from '../../withError';

const sleep = (ms: number) => new Promise((resolve) => setTimeout(resolve, ms));

import { storage } from '@/app/lib/storage';
import { type ReportHistory } from '@/app/lib/storage/types';
import { env } from '@/app/config/env';

type ReportsMap = Map<string, ReportHistory>;

const reportcacheProcessKey = Symbol.for('playwright.reports.reportCache');

export class ReportCache {
  public initialized = false;
  private readonly reports: ReportsMap;

  private constructor() {
    this.reports = new Map();
  }

  public static getInstance() {
    const nodeJsProcess = process as typeof process & { [key: symbol]: ReportCache | undefined };

    if (!nodeJsProcess[reportcacheProcessKey]) {
      nodeJsProcess[reportcacheProcessKey] = new ReportCache();
    }

    return nodeJsProcess[reportcacheProcessKey]!;
  }

  public async init() {
    if (this.initialized || !env.USE_SERVER_CACHE) {
      return;
    }

    const maxAttempts = 6;
    const retryDelayMs = 10_000;

    for (let attempt = 1; attempt <= maxAttempts; attempt++) {
      console.log(`[report cache] initializing cache (attempt ${attempt}/${maxAttempts})`);
      const { result, error } = await withError(storage.readReports({ lightweight: true }));

      if (error) {
        console.error('[report cache] failed to read reports:', error);
        if (attempt < maxAttempts) await sleep(retryDelayMs);
        continue;
      }

      if (!result?.reports?.length) {
        console.log('[report cache] no reports found yet');
        if (attempt < maxAttempts) await sleep(retryDelayMs);
        continue;
      }

      for (const report of result.reports) {
        ReportCache.getInstance().reports.set(report.reportID, report);
      }

      this.initialized = true;
      console.log(`[report cache] initialized with ${result.reports.length} reports`);
      return;
    }

    console.warn('[report cache] init finished without reports');
  }

  public onDeleted(reportIds: string[]) {
    if (!env.USE_SERVER_CACHE) {
      return;
    }

    for (const id of reportIds) {
      this.reports.delete(id);
    }
  }

  public onCreated(report: ReportHistory) {
    if (!env.USE_SERVER_CACHE) {
      return;
    }
    this.reports.set(report.reportID, report);
  }

  public getAll(): ReportHistory[] {
    return Array.from(this.reports.values());
  }

  public getByID(reportID: string): ReportHistory | undefined {
    return this.reports.get(reportID);
  }
}

export const reportCache = ReportCache.getInstance();
