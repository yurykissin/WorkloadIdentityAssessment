import assert from 'node:assert/strict';
import { copyFile, mkdir, mkdtemp, readFile, readdir, rmdir, unlink } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { chromium } from 'playwright';

const here = dirname(fileURLToPath(import.meta.url));
const root = resolve(process.env.REPORT_TEST_OUTPUT || join(here, '../output/report-tests'));
const screenshots = process.env.UPDATE_REPORT_SCREENSHOTS === '1'
  ? resolve(here, '../docs/screenshots') : join(root, 'screenshots');
await mkdir(screenshots, { recursive: true });
const moved = await mkdtemp(join(tmpdir(), 'workload-report-'));
const movedReport = join(moved, 'report.html');
await copyFile(join(root, 'normal/report.html'), movedReport);
assert.deepEqual(await readdir(moved), ['report.html']);
const browser = await chromium.launch({ channel: process.env.REPORT_BROWSER_CHANNEL || 'chrome', headless: true });
const context = await browser.newContext({ viewport: { width: 1440, height: 1080 }, offline: true });
const page = await context.newPage();
const errors = [];
const externalRequests = [];
page.on('pageerror', error => errors.push(error.message));
page.on('console', message => { if (message.type() === 'error') errors.push(message.text()); });
page.on('request', request => { if (!request.url().startsWith('file:') && !request.url().startsWith('data:')) externalRequests.push(request.url()); });
let checks = 0;
const check = (condition, message) => { assert.ok(condition, message); checks++; };
const open = async name => {
  await page.goto(name === 'moved' ? pathToFileURL(movedReport).href : pathToFileURL(join(root, name, 'report.html')).href);
  await page.locator('#overview-cards .card').first().waitFor();
};
const tab = id => page.locator(`#tab-${id}`).click();
const visibleCount = selector => page.locator(selector).count();
async function noOverflow(label) {
  check(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth + 1), `${label}: no page-wide horizontal overflow`);
  const title = await page.locator('.view:visible h2').boundingBox();
  const navigation = await page.locator('.tabs').boundingBox();
  check(title.y >= navigation.y + navigation.height - 1, `${label}: heading is not hidden behind sticky navigation`);
}
async function screenshot(name) {
  await page.screenshot({ path: join(screenshots, name), fullPage: true });
}

try {
  await open('credential-preview');
  await tab('credentials');
  check(await page.locator('#credentials').innerText().then(value => value.includes('Credential activity (preview): Available') && value.includes('Inactive >= 90 days') && value.includes('No matching activity')), 'Credential usage and unknown matching evidence are visible separately from expiry');
  const previewTable = page.locator('#credentials .data-table').first();
  await previewTable.getByRole('button', { name: 'Technical details', exact: true }).first().click();
  await page.locator('#technical-panel[open] dt').getByText('Activity Evidence', { exact: true }).waitFor();
  check(await page.locator('#technical-panel').innerText().then(value => value.includes('synthetic-activity')), 'Matched activity evidence remains inspectable in the side panel');
  await page.keyboard.press('Escape');
  await tab('permissions');
  check(await page.locator('#permissions .permission-section tr.issue-high').count() === 1 &&
    await page.locator('#permissions .permission-section tr.issue-info').count() === 1 &&
    await page.locator('#permissions .permission-section tr.issue-low').count() === 1,
    'Unresolved null-name evidence flags only its own Low row, never unrelated High or Info grants on the same principal');
  check(await page.locator('#permissions').innerText().then(value => value.includes('Info - AZTier Tier 2') && value.includes('Low / Unrated - unresolved')), 'Privilege review distinguishes researched inventory Info and unresolved Low / Unrated');
  await tab('findings');
  check(await page.getByRole('table', { name: 'Assessment findings', exact: true }).count() === 1 &&
    await page.locator('.findings-table > thead th').allTextContents().then(values => values.join('|') === 'Severity|Finding|Outcome|Affected / eligible|Details'),
    'Findings use a compact table with severity, title, outcome, affected count and expansion controls');
  check(await page.locator('.finding-details:visible').count() === 0 && await page.locator('#findings a:visible').count() === 0,
    'Finding explanations and source links are collapsed by default rather than filling the overview');
  const firstFinding = page.locator('.finding').first();
  const findingToggle = firstFinding.locator('[data-finding-toggle]');
  await findingToggle.focus();
  await page.keyboard.press('Enter');
  check(await findingToggle.getAttribute('aria-expanded') === 'true' && await firstFinding.locator('.finding-details').isVisible(),
    'Enter expands finding details with synchronized accessible state');
  check(await firstFinding.locator('a:visible').count() === 0, 'Opening a finding does not dump its source links until Sources is expanded');
  await firstFinding.locator('.finding-sources summary').click();
  check(await firstFinding.locator('a:visible').count() > 0, 'Source references remain available through a nested native disclosure');
  await firstFinding.locator('.finding-sources summary').click();
  await findingToggle.focus();
  await page.keyboard.press('Space');
  check(await findingToggle.getAttribute('aria-expanded') === 'false' && !await firstFinding.locator('.finding-details').isVisible(),
    'Space collapses the row without losing keyboard focus or evidence state');
  await page.locator('#finding-severity').selectOption('High');
  check(await page.locator('#findings').innerText().then(value => value.includes('High-priority API grants require review') && value.includes('Privileged Azure roles')), 'Privileged grants are actionable High review candidates');
  await open('credential-preview-denied');
  await tab('credentials');
  check(await page.locator('#credentials').innerText().then(value => value.includes('Unavailable') && value.includes('Not assessed')), 'Denied preview access is not presented as zero unused credentials');

  await open('failed-collectors');
  await tab('inventory');
  check(await page.locator('#inventory').innerText().then(value => value.includes('Failed:') && value.includes('Synthetic inventory failure') && value.includes('transcript.txt')), 'Inventory shows the known collection failure and diagnostic path');
  await tab('permissions');
  check(await page.locator('#permissions').innerText().then(value => value.includes('Synthetic null resource failure') && !value.includes('status unknown')), 'Permissions show the known collection error rather than an unexplained missing file');

  await open('entra');
  check(await page.locator('#overview-cards .card-value').nth(2).innerText() === 'Not collected', 'Entra-only overview never displays Azure managed identities as zero');
  check(await page.locator('#overview .properties').innerText().then(value => value.includes('Entra only')), 'Chosen assessment scope is visible');
  await tab('inventory');
  check(await page.locator('#inventory').innerText().then(value => value.includes('Azure checks not collected')), 'Mixed inventory explains excluded Azure checks');
  check(await page.locator('#identity-detail').innerText().then(value => value.includes('Azure RBAC not collected')), 'Identity details distinguish excluded RBAC from zero matching grants');
  await tab('monitoring');
  check(await page.locator('#monitoring').innerText().then(value => value.includes('Not collected')), 'Azure monitoring is labelled not collected');
  await tab('permissions');
  check(await page.locator('#permissions .tile-value').allTextContents().then(values => values.includes('Not collected')), 'Excluded RBAC metric is not a zero-result badge');
  check(errors.length === 0 && externalRequests.length === 0, 'Entra-only report remains error-free and offline');

  await open('moved');
  check(await page.locator('#overview-cards .card-value').allTextContents().then(values => values.join(',') === '3,3,1,1,2,4'), 'Inventory totals retained with explicit source-backed predicate findings');
  check(await visibleCount('#source-table .badge.loaded') === 8, 'Eight source files shown as loaded');
  check(await page.locator('body').evaluate(element => getComputedStyle(element).backgroundColor) === 'rgb(15, 20, 32)', 'CAPVisualizer background palette applied');
  await screenshot('01-header-and-nav.png');
  for (const id of ['inventory', 'findings', 'controls', 'credentials', 'fic', 'permissions', 'stale', 'monitoring', 'ca', 'tenant', 'raw', 'overview']) {
    await tab(id);
    check(await page.locator(`#${id}`).isVisible(), `${id} tab works`);
    check(await visibleCount('.view:visible') === 1, `${id}: only the selected view is visible`);
    await noOverflow(`desktop ${id}`);
  }

  await tab('inventory');
  check(await visibleCount('.identity-item') === 3, 'Tenant-managed app/SP pairs each occupy one workload row');
  check(await page.locator('#identity-category').inputValue() === 'Tenant-managed', 'Microsoft, external and managed identities are not mixed into the default view');
  await page.getByRole('button', { name: 'Technical details and identifiers', exact: true }).first().click();
  check((await page.locator('#technical-panel').innerText()).includes('Application object ID'), 'Application object ID is distinguished in the technical panel');
  check((await page.locator('#technical-panel').innerText()).includes('Application (client) ID'), 'Application client ID is distinguished');
  check(await page.locator('#technical-panel .properties dd').evaluateAll(elements => elements.every(element => element.getBoundingClientRect().width >= 200)), 'Desktop technical values never collapse into a zero-width column');
  await page.keyboard.press('Escape');
  check(await page.getByRole('button', { name: 'Technical details and identifiers', exact: true }).first().evaluate(element => element === document.activeElement), 'Escape returns focus to the invoking button');
  check(await visibleCount('#identity-detail .data-table') === 3, 'App credentials, federation and Graph permissions joined through reliable IDs');
  await screenshot('05-inventory.png');
  await page.locator('#identity-category').selectOption('all');
  await page.locator('#identity-type').selectOption('mi');
  check(await visibleCount('.identity-item') === 1, 'Managed-identity type filter works');
  await page.getByRole('button', { name: 'Technical details and identifiers', exact: true }).click();
  check((await page.locator('#technical-panel').innerText()).includes('Azure resource ID'), 'MI resource ID is distinguished');
  await page.locator('#technical-close').click();
  check((await page.locator('#identity-detail').innerText()).includes('Reader'), 'MI RBAC principal-ID join works');
  await page.locator('#identity-search').fill('does-not-exist');
  check(await visibleCount('.identity-item') === 0, 'Identity search has an honest zero-result state');
  await page.locator('#identity-search').fill('');
  await page.locator('#identity-type').selectOption('all');

  await tab('findings');
  check((await page.locator('.findings-table').boundingBox()).height <= 600, 'Six collapsed findings fit in a compact desktop table instead of long cards');
  await page.locator('#finding-severity').selectOption('High');
  check(await visibleCount('.finding:visible') === 2, 'Severity filtering includes the High privilege review');
  await screenshot('02-findings-high.png');
  await page.locator('#finding-severity').selectOption('Med');
  check(await visibleCount('.finding:visible') === 4, 'Medium governance observations have explicit predicates');
  await screenshot('03-findings-med-low-info.png');
  await page.getByRole('searchbox', { name: 'Search findings and recommendations', exact: true }).fill('minimizing privileged ownership');
  check(await visibleCount('.finding:visible') === 1, 'Finding recommendations are searchable');
  await page.getByRole('searchbox', { name: 'Search findings and recommendations', exact: true }).fill('no-such-finding');
  check(await page.locator('.findings-table-wrap').isHidden() && await page.getByText('No matching findings.', { exact: true }).isVisible(),
    'An empty finding filter hides the empty table and shows an honest no-match state');
  await page.locator('#global-search').fill('WI.REG.1');
  await page.locator('#global-search').press('Enter');
  check(await page.locator('.finding:focus').count() === 1, 'Global search navigates to its exact finding');
  check(await visibleCount('.finding:visible') === 6, 'Global finding navigation clears stale filters');
  const affected = page.locator('.finding').filter({ hasText: 'WI.OWN.1' });
  await affected.locator('[data-finding-affected]').click();
  check(await affected.locator('.finding-evidence tbody tr').count() === 1 && await affected.locator('[data-finding-toggle]').getAttribute('aria-expanded') === 'true',
    'Affected-count shortcut expands the row and loads the exact affected SP directly');
  await affected.getByRole('button', { name: 'Open enterprise application', exact: true }).click();
  check(await page.locator('.counterpart-focused').innerText().then(value => value.includes('service principal') && value.includes('WI.OWN.1')), 'Affected-object navigation focuses the exact SP and its source-backed field flags');
  await tab('findings');
  check(await affected.locator('.finding-evidence').isVisible(), 'Returning preserves the expanded evidence list');
  await affected.locator('[data-finding-toggle]').click();
  check(await affected.locator('[data-finding-affected]').getAttribute('aria-expanded') === 'false', 'Collapsing a row does not claim its affected list is visible');
  await affected.locator('[data-finding-toggle]').click();
  check(await affected.locator('.finding-evidence').isVisible() && await affected.locator('[data-finding-affected]').getAttribute('aria-expanded') === 'true',
    'Reopening a row restores its existing affected list and accessible shortcut state');
  await page.locator('#global-search').fill('00000000-0000-0000-0004-000000000001');
  await page.locator('#global-search').press('ArrowDown');
  await page.keyboard.press('Enter');
  check((await page.locator('#identity-detail').innerText()).includes('synthetic-build-identity'), 'Keyboard global search navigates by principal ID');
  await page.locator('#global-search').fill('');

  await tab('credentials');
  const credentialTable = page.locator('#credentials .data-table').first();
  await credentialTable.getByRole('combobox', { name: /Expired/ }).selectOption('0');
  check(await credentialTable.locator('tbody tr').count() === 1, 'Credential expiry filter works');
  await credentialTable.getByRole('button', { name: 'Technical details', exact: true }).first().click();
  check((await page.locator('#technical-panel').innerText()).includes('Application object ID'), 'All row fields are inspectable beyond visible columns');
  await page.locator('#technical-close').click();
  await screenshot('06-credentials-fic.png');
  await tab('tenant');
  await screenshot('04-tenant-context.png');
  await page.locator('#tab-tenant').focus();
  await page.keyboard.press('ArrowRight');
  check(await page.locator('#tab-raw').getAttribute('aria-selected') === 'true', 'Keyboard arrow navigation switches tabs');

  await open('paired');
  await tab('inventory');
  check(await visibleCount('.identity-item') === 4, 'Default paired inventory includes three local app/SP workloads and a registration without a local SP');
  check((await page.locator('.workload-table th').allTextContents()).join('|') === 'Name', 'Inventory selector shows application names without redundant counterpart columns');
  check(await page.locator('.workload-table button:not(.identity-item)').count() === 0, 'Name selection is the only action in the inventory list');
  check(await page.locator('#inventory').getByRole('button', { name: /^Open (app registration|enterprise application|managed identity)$/ }).count() === 0, 'Related inventory tables do not link back to the objects already being displayed');
  check(await page.locator('#identity-detail').getByRole('button', { name: 'Technical details', exact: true }).count() > 0, 'Removing redundant links preserves technical evidence access');
  const pairedPanels = page.locator('#identity-detail .counterpart-pair .counterpart-panel');
  check(await pairedPanels.count() === 2, 'App registration and local enterprise app are simultaneously visible');
  const appBox = await pairedPanels.nth(0).boundingBox();
  const spBox = await pairedPanels.nth(1).boundingBox();
  check(Math.abs(appBox.y - spBox.y) < 2 && spBox.x >= appBox.x + appBox.width && appBox.width >= 300 && spBox.width >= 300, 'Desktop counterpart panels are side by side with readable widths');
  await page.locator('#global-search').fill('00000000-0000-0000-0003-000000000001');
  await page.locator('#global-search').press('Enter');
  await page.locator('#global-search').fill('');
  check(await page.locator('.counterpart-focused').innerText().then(value => value.includes('Different SP display name')), 'External navigation still focuses the exact SP in the name-only workspace');
  check(await pairedPanels.count() === 2, 'Focusing a counterpart does not hide its paired object');
  check(await pairedPanels.nth(0).locator('[data-setting="OwnerCount"].issue-med').count() === 2, 'App ownership warning highlights only its assessed setting and retains its severity');
  check(await pairedPanels.nth(0).locator('[data-setting="SignInAudience"].issue-med, [data-setting="CreationEvidence"].issue-med').count() === 0, 'Audience and unavailable creator evidence are not fabricated Medium failures');
  const exportedKeys = await page.evaluate(() => Object.keys(JSON.parse(document.getElementById('report-data').textContent).Data['02'].appRegistrations[0]));
  const renderedKeys = await pairedPanels.nth(0).locator('[data-setting]').evaluateAll(elements => elements.map(element => element.dataset.setting));
  check(exportedKeys.every(key => renderedKeys.includes(key)), 'Every exported registration field is available in a readable settings group');
  check((await pairedPanels.locator('.settings-group summary').allTextContents()).every(value => !/\(\d+ fields\)/.test(value)), 'Settings headings never present field totals as if they were owner or configuration counts');
  check(await pairedPanels.nth(0).locator('.settings-group summary').filter({ hasText: /^Ownership$/ }).count() === 1, 'Ownership group is labelled plainly without a misleading count');
  await pairedPanels.nth(0).locator('summary').filter({ hasText: 'Authentication and audience' }).click();
  check(await pairedPanels.nth(0).innerText().then(value => value.includes('https://example.invalid/callback') && value.includes('Enable Access Token Issuance') && value.includes('false')), 'Nested redirect and flow settings are readable without raw JSON');
  const relatedConfigured = page.locator('#identity-detail [data-permission-section="configured"]');
  const relatedOther = page.locator('#identity-detail [data-permission-section="other-granted"]');
  const relatedUnknown = page.locator('#identity-detail [data-permission-section="configuration-unavailable"]');
  check(await relatedConfigured.locator('tbody tr').count() === 2, 'Application configured section contains both granted and not-granted requests');
  check(await relatedConfigured.innerText().then(value => value.includes('Synthetic.Read') && value.includes('Synthetic.Write') && value.includes('Not granted')), 'Configured request rows expose their actual grant state');
  check(await relatedOther.locator('tbody tr.issue-high').count() === 1 && await relatedConfigured.locator('tbody tr.issue-high').count() === 0, 'Only the exact high-impact grant is red, not every permission belonging to that app');
  check(await relatedOther.innerText().then(value => value.includes('Exchange.ManageAsApp') && value.includes('High / Review / WI.PERM.1')), 'Granted-only access has a separate section with explicit source-backed Review, not an invented configuration failure');
  check(await relatedUnknown.locator('tbody tr').count() === 0, 'Known local configuration is not mixed into unavailable-configuration grants');
  let previousDetailWidth = 0;
  for (const width of [1024, 1440, 1920, 2560]) {
    await page.setViewportSize({ width, height: 1080 });
    await tab('inventory');
    const content = await page.locator('#inventory').boundingBox();
    const sidebar = await page.locator('.identity-sidebar').boundingBox();
    const details = await page.locator('#identity-detail').boundingBox();
    check(content.x <= 25 && content.x + content.width >= width - 25, `Inventory uses the available page width at ${width}px without capped side gutters`);
    check(sidebar.width <= 341 && details.width > previousDetailWidth && details.x + details.width >= width - 25, `Detail area grows with viewport width at ${width}px while the name sidebar stays bounded`);
    previousDetailWidth = details.width;
    await noOverflow(`fluid inventory ${width}px`);
  }
  await page.setViewportSize({ width: 1440, height: 1080 });
  await pairedPanels.nth(1).locator('[data-setting="OwnerCount"]').first().getByRole('button', { name: /WI.OWN.1/ }).click();
  check(await page.locator('.finding:focus').innerText().then(value => value.includes('WI.OWN.1')), 'Inline warning links to its exact global finding');
  await tab('inventory');
  check(await page.locator('#identity-detail h4').allTextContents().then(values => !values.includes('Related findings')), 'No selected-workload issues panel is added against the confirmed global-only choice');
  await page.locator('#identity-search').fill('Same display name');
  check(await visibleCount('.identity-item') === 2, 'Identical display names never merge distinct client IDs');
  await page.locator('#identity-search').fill('Registration without enterprise app');
  await page.locator('.identity-item').click();
  check(await page.locator('#identity-detail .counterpart-state').innerText().then(value => value.includes('No matching local enterprise application exported') && value.includes('global non-use')), 'Registration-only workloads show an explicit neutral local-SP state without claiming global inactivity');
  check(await relatedConfigured.innerText().then(value => value.includes('Synthetic.Delegated') && value.includes('Unknown') && !value.includes('Granted application access')), 'Unknown consent remains unknown for a configured request with no exported SP');
  await page.getByRole('button', { name: 'View all findings', exact: true }).click();
  await page.locator('#finding-severity').selectOption('High');
  await tab('inventory');
  await page.getByRole('button', { name: 'View all findings', exact: true }).click();
  check(await page.locator('#finding-severity').inputValue() === 'all', 'View all findings clears stale severity filters instead of hiding other issues');
  await tab('inventory');
  await page.locator('#identity-category').selectOption('all');
  await page.locator('#identity-search').fill('External-only workload');
  await page.locator('.identity-item').click();
  check(await page.locator('#identity-detail .counterpart-state').innerText().then(value => value.includes('External app definition')), 'External-only SPs do not masquerade as locally missing registrations');
  check(await relatedUnknown.locator('tbody tr').count() === 1 && await relatedOther.locator('tbody tr').count() === 0, 'External configuration is unavailable, never granted-but-not-configured');
  await page.locator('#identity-search').fill('');
  await page.locator('#identity-type').selectOption('mi');
  check(await visibleCount('.identity-item') === 1 && await page.locator('#identity-detail .counterpart-panel').count() === 2, 'Managed identity resource and its SP share one workload without an invented registration');
  check(await page.locator('#identity-detail').innerText().then(value => value.includes('managed identities do not have an app registration') && value.includes('Reader')), 'Managed identity lifecycle and RBAC remain accessible alongside the directory object');
  await page.locator('#identity-type').selectOption('agent');
  check(await visibleCount('.identity-item') === 1 && await pairedPanels.count() === 2, 'Agent identity and blueprint evidence remain paired and navigable');
  await tab('permissions');
  check(await page.locator('#permissions [data-permission-section="configured"] tbody tr').count() === 3, 'Global configured section covers every configured request');
  check(await page.locator('#permissions [data-permission-section="other-granted"] tbody tr').count() === 1, 'Global granted-only section is distinct from requests');
  check(await page.locator('#permissions [data-permission-section="configuration-unavailable"] tbody tr').count() === 1, 'Global unavailable-configuration section preserves external grants');
  await page.locator('#permissions [data-permission-section="other-granted"]').getByRole('button', { name: 'Open enterprise application', exact: true }).click();
  check(await page.locator('.counterpart-focused').innerText().then(value => value.includes('Different SP display name')), 'Grant navigation prioritizes SP object ID over the shared client ID');
  await tab('credentials');
  await page.locator('#credentials .data-table').first().getByRole('button', { name: 'Open enterprise application', exact: true }).click();
  check(await page.locator('.counterpart-focused').innerText().then(value => value.includes('Different SP display name')), 'Credential evidence can explicitly open the paired enterprise app');
  await tab('credentials');
  await page.locator('#credentials .data-table').first().getByRole('button', { name: 'Open app registration', exact: true }).click();
  check(await page.locator('.counterpart-focused').innerText().then(value => value.includes('App registration') && value.includes('Same display name')), 'Credential evidence can explicitly open its owning registration');
  await page.setViewportSize({ width: 390, height: 844 });
  const mobileApp = await pairedPanels.nth(0).boundingBox();
  const mobileSp = await pairedPanels.nth(1).boundingBox();
  check(mobileSp.y >= mobileApp.y + mobileApp.height && mobileApp.width >= 300, 'Mobile counterpart panels stack with usable content widths');
  check(await pairedPanels.locator('.properties dd').evaluateAll(elements => elements.filter(element => element.getClientRects().length).every(element => element.getBoundingClientRect().width >= 240)), 'Nested paired settings never collapse to unreadable zero-width columns on mobile');
  await tab('inventory');
  await noOverflow('mobile paired inventory');
  await page.setViewportSize({ width: 1440, height: 1080 });

  await open('exposure-review');
  await tab('credentials');
  const lifetimeTable = page.locator('#credentials .data-table').first();
  check(await lifetimeTable.getByRole('button', { name: 'Secret Lifetime Status', exact: true }).isVisible(), 'Credentials expose readable lifetime status beside start/end dates');
  check(await lifetimeTable.locator('tbody tr.issue-high').count() === 2, 'Only the long-lived and unknown-expiry secrets have High lifetime findings, not certificates or the threshold boundary');
  await lifetimeTable.getByRole('combobox', { name: /Secret Lifetime Status/ }).selectOption({ label: 'Unknown expiry - missing or invalid end date' });
  check(await lifetimeTable.locator('tbody tr').count() === 1 && (await lifetimeTable.innerText()).includes('Unknown expiry secret'), 'Missing expiry is searchable/filterable as unknown, never presented as proven infinite validity');
  await lifetimeTable.getByRole('combobox', { name: /Secret Lifetime Status/ }).selectOption('');
  await tab('inventory');
  const redirects = page.locator('#identity-detail .data-table').filter({ has: page.getByRole('button', { name: 'Redirect Uri', exact: true }) });
  check(await redirects.locator('tbody tr').count() === 3 && await redirects.locator('tbody tr.issue-med').count() === 2, 'Per-app ownership review shows every exported URI and flags only exact network redirects');
  const nativeRedirect = redirects.locator('tbody tr').filter({ hasText: 'native-app://callback' });
  check(!/\bissue-(high|med)\b/.test(await nativeRedirect.getAttribute('class') || ''), 'A native redirect does not inherit another URI finding on the same application');
  check(await redirects.locator('a').count() === 0 && (await page.locator('#identity-detail').innerText()).includes('No network probes are performed'), 'Exported redirect targets are plain text and current ownership limitations are explicit');
  check((await page.locator('#identity-detail [data-related="credentials"]').innerText()).includes('SP long-lived secret'), 'SP-origin credentials and their lifetime are visible alongside application credentials');
  await tab('permissions');
  const consentGrants = page.locator('#permissions [data-permission-section="other-granted"]');
  check(await consentGrants.locator('tbody tr').count() === 3 && await consentGrants.locator('tbody tr.issue-high').count() === 1 && await consentGrants.locator('tbody tr.issue-info').count() === 1, 'Broad consent keeps basic User.Read informational and Mail.Read High without affecting a specific-user grant');
  await consentGrants.getByRole('combobox', { name: /Consent Audience/ }).selectOption({ label: 'Organization-wide (all users)' });
  check(await consentGrants.locator('tbody tr').count() === 2, 'Permissions can be filtered directly to organization-wide delegated consent');
  await consentGrants.getByRole('combobox', { name: /Consent Audience/ }).selectOption({ label: 'Specific user' });
  check(await consentGrants.locator('tbody tr').count() === 1 && await consentGrants.locator('tbody tr.issue-info, tbody tr.issue-high').count() === 0, 'Specific-user User.Read does not inherit the organization-wide grant finding');
  check(await page.locator('#permissions [data-permission-section="configured"] tbody tr.issue-high, #permissions [data-permission-section="configured"] tbody tr.issue-info').count() === 0, 'Configured-only scopes never masquerade as actual broad consent');
  await tab('findings');
  const ownershipFinding = page.locator('.finding').filter({ hasText: 'WI.APP.4' });
  await ownershipFinding.locator('[data-finding-affected]').click();
  check(await ownershipFinding.locator('.finding-evidence tbody tr').count() === 2 && (await ownershipFinding.locator('.finding-evidence').innerText()).includes('https://retired-domain.invalid/callback'), 'Ownership findings expose exact URI, host and ownership uncertainty, not only the application name');
  await ownershipFinding.locator('.finding-evidence').getByRole('button', { name: 'Open app registration', exact: true }).first().click();
  check((await page.locator('.counterpart-focused').innerText()).includes('Synthetic workload 0001'), 'Redirect evidence navigation opens the owning registration using its object ID');
  await tab('findings');
  const consentFinding = page.locator('.finding').filter({ hasText: 'WI.CONSENT.1' });
  await consentFinding.locator('[data-finding-affected]').click();
  check(await consentFinding.locator('.finding-evidence tbody tr').count() === 2 && (await consentFinding.locator('.finding-evidence').innerText()).includes('Organization-wide (all users)'), 'Informational consent findings retain exact granted scopes and readable audience evidence');
  await page.setViewportSize({ width: 390, height: 844 });
  await tab('findings');
  await noOverflow('mobile exposure findings');
  await tab('inventory');
  await noOverflow('mobile exposure inventory');
  check(errors.length === 0 && externalRequests.length === 0, 'Exposure review remains error-free and performs no domain, HTTP or registration lookups');
  await page.setViewportSize({ width: 1440, height: 1080 });

  await open('permission-risk');
  await tab('permissions');
  const riskGrants = page.locator('#permissions [data-permission-section="other-granted"]');
  check(await riskGrants.locator('tbody tr.issue-high').count() === 6 && await riskGrants.locator('tbody tr.issue-med').count() === 3 &&
    await riskGrants.locator('tbody tr.issue-info').count() === 4 && await riskGrants.locator('tbody tr.issue-low').count() === 3,
  'Risk view preserves capability ratings while adding informational organization-wide consent visibility for basic User.Read');
  check(await riskGrants.getByRole('button', { name: /WI.PERM.6/ }).count() === 3, 'Exactly the original three inventory permissions retain Info capability findings; consent does not rewrite grading');
  check(await page.locator('#permissions .permission-methodology').isVisible() &&
    await page.locator('#permissions .permission-methodology').innerText().then(value => value.includes('0=High, 1=Medium, 2=Info') && value.includes('Low is not a researched low-risk') && value.includes('2025-10-30') && value.includes('2026-10-23')),
  'Visible disclaimer explains the severity policy, unrated caveat and different research/discovery dates');
  const createRisk = riskGrants.locator('tbody tr').filter({ hasText: 'AgentIdentityBlueprintPrincipal.Create' });
  check(await createRisk.innerText().then(value => value.includes('Dangerous capability - review') && value.includes('Toolkit capability extension') && value.includes('Delegated access is bounded')), 'Agent create grants show readable risk, honest source origin and delegated access context');
  check(await createRisk.getByRole('link', { name: 'Microsoft source', exact: true }).getAttribute('href') === 'https://learn.microsoft.com/en-us/graph/permissions-reference', 'Capability extensions link to official permission descriptions');
  const mailRisk = riskGrants.locator('tbody tr').filter({ has: page.locator('td', { hasText: /^Microsoft Graph$/ }) }).filter({ has: page.locator('td', { hasText: /^Delegated$/ }) }).filter({ has: page.locator('td', { hasText: /^Mail.Read$/ }) });
  check(await mailRisk.getByRole('link', { name: 'Microsoft source', exact: true }).getAttribute('href') === 'https://learn.microsoft.com/en-us/security/operations/incident-response-playbook-app-consent#classifying-risky-permissions', 'Published delegated mail category links to Microsoft risky-permission list even without admin consent');
  const lowRisk = riskGrants.locator('tbody tr').filter({ has: page.locator('td', { hasText: /^User.Read$/ }) });
  check(!/\bissue-(high|med)\b/.test(await lowRisk.getAttribute('class') || '') && (await lowRisk.innerText()).includes('Lower impact - not a safety assurance'), 'User.Read has no fabricated dangerous flag or verified-safe claim');
  check(await lowRisk.getByRole('button', { name: /WI.CONSENT.1/ }).count() === 1 && await lowRisk.getByRole('button', { name: /WI.PERM.6/ }).count() === 0, 'Basic User.Read is visible for organization-wide consent only, not reclassified as risky inventory access');
  check(await page.locator('#permissions [data-permission-section="configured"] tbody tr.issue-high').count() === 0, 'Dangerous but not-granted requests do not masquerade as existing dangerous grants');
  const applicationRisk = name => riskGrants.locator('tbody tr').filter({ has: page.locator('td', { hasText: /^Application$/ }) }).filter({ has: page.locator('td', { hasText: new RegExp(`^${name.replaceAll('.', '\\.')}$`) }) });
  const delegatedRisk = name => riskGrants.locator('tbody tr').filter({ has: page.locator('td', { hasText: /^Delegated$/ }) }).filter({ has: page.locator('td', { hasText: new RegExp(`^${name.replaceAll('.', '\\.')}$`) }) });
  for (const name of ['AgentIdentity.Read.All', 'Application.Read.All']) {
    const inventoryRead = delegatedRisk(name);
    check(await inventoryRead.getAttribute('class') === 'issue-info' && await inventoryRead.innerText().then(value => value.includes('Info - inventory read')) &&
      await inventoryRead.getByRole('button', { name: /High \/ Review/ }).count() === 0, `${name} delegated inventory is Info, visible without a red risk warning`);
  }
  for (const name of ['AuditLog.Read.All', 'IdentityRiskEvent.Read.All']) {
    check(await delegatedRisk(name).getAttribute('class') === 'issue-med' && await delegatedRisk(name).innerText().then(value => value.includes('Medium - security/audit read')),
      `${name} delegated security read is Medium, not flattened into Info or High`);
  }
  const applicationRead = applicationRisk('Application.Read.All');
  check(await applicationRead.getAttribute('class') === 'issue-info' && await applicationRead.innerText().then(value => value.includes('AZTier Tier 2') && value.includes('Capability context (TK.GRAPH.READ)') && !value.includes('Additional capability warning')),
    'Application inventory read retains AZTier Info with informational context, not an elevated-risk notice');
  check((await applicationRead.getByRole('link', { name: 'AZTier source', exact: true }).getAttribute('href')).includes('/7738e071a2087c79626875f890cd4f6476fd848d/'),
    'Per-row AZTier source is pinned to the imported revision, not a mutable main URL');
  check(await applicationRisk('Mail.Read').getAttribute('class') === 'issue-med' && await applicationRisk('Mail.Read').innerText().then(value => value.includes('AZTier Tier 1') && value.includes('MS.IR.SENSITIVE')),
    'Sensitive application reads are Medium rather than automatically Info and retain Microsoft capability context');
  const untieredAgent = applicationRisk('AgentIdentity.Read.All');
  check(await untieredAgent.getAttribute('class') === 'issue-low' && await untieredAgent.innerText().then(value => value.includes('manual review pending') && value.includes('not a researched low-risk') && value.includes('TK.AGENT.READ')),
    'New unreviewed Agent application access is Low / Unrated with its separate capability warning, not claimed safe');
  check((await untieredAgent.getByRole('link', { name: 'AZTier source', exact: true }).getAttribute('href')).endsWith('untiered-msgraph-app-permissions.json'),
    'Unreviewed permission links to detections, not a nonexistent published risk tier');
  const tierZero = applicationRisk('AppRoleAssignment.ReadWrite.All');
  check(await tierZero.getAttribute('class') === 'issue-high' &&
    await tierZero.getByRole('link', { name: 'SpecterOps research' }).count() === 1 && await tierZero.getByRole('link', { name: 'Semperis research' }).count() === 1,
    'Permission-grant control stays High with AZTier plus concrete corroborating research links');
  await createRisk.getByRole('button', { name: /High \/ Review \/ WI.PERM.1/ }).click();
  check(await page.locator('.finding:focus').innerText().then(value => value.includes('official requirements never suppress exposure')), 'Risk finding explains that officially required access remains exposed for review');
  check(await page.locator('#findings .finding-disclaimer').isVisible() && !await page.locator('#findings .permission-methodology').isVisible(),
    'Findings retain a short visible safety disclaimer without repeating the full methodology block');
  await page.locator('#findings .finding-methodology > summary').click();
  check(await page.locator('#findings .permission-methodology').isVisible(), 'The full grading methodology and source dates remain expandable on Findings');
  await page.locator('#findings .finding-methodology > summary').click();
  await tab('controls');
  check(await page.locator('#controls .permission-methodology').isVisible(), 'Control coverage displays grading methodology and caveats');
  await page.getByRole('button', { name: 'Permission risk catalog and sources', exact: true }).click();
  check(await page.locator('#technical-panel').innerText().then(value => value.includes('MS.IR.SENSITIVE') && value.includes('TK.AGENT.WRITE') && value.includes('2026-10-24')), 'Full versioned risk catalog and labelled origins remain accessible offline');
  const mappingTable = page.locator('#technical-content .data-table').last();
  check(await mappingTable.innerText().then(value => value.includes('772 exported rows')), 'Readable offline mapping browser includes all 614 reviewed and 158 untiered entries');
  await mappingTable.getByRole('searchbox').fill('AgentIdentity.Read.All');
  check(await mappingTable.locator('tbody tr').count() === 1 && await mappingTable.innerText().then(value => value.includes('Untiered / Unrated') && value.includes('Low')), 'Complete mapping list is searchable and does not invent a tier for new permissions');
  await page.keyboard.press('Escape');

  await open('principal-only');
  await tab('inventory');
  await page.locator('#identity-category').selectOption('all');
  await page.locator('#identity-type').selectOption('mi');
  check(await visibleCount('.identity-item') === 1 && await page.locator('#identity-detail .counterpart-panel').count() === 2, 'Matching principal IDs pair MI resource and SP case-insensitively even when neither client ID was collected');

  await open('large');
  await tab('inventory');
  check(await visibleCount('.identity-item') === 50, 'Large identity inventory is paged');
  await page.locator('#identity-search').fill('Synthetic workload 0550');
  check(await visibleCount('.identity-item') === 1, 'App and SP beyond old row caps are searchable as one workload');
  await page.locator('.identity-item').click();
  await page.locator('#identity-detail .counterpart-pair .counterpart-panel').nth(1).getByRole('button', { name: 'Technical details and identifiers', exact: true }).click();
  check((await page.locator('#technical-panel').innerText()).includes('00000000-0000-0000-0003-000000000550'), 'Tail SP details are accessible');
  await page.keyboard.press('Escape');
  await page.locator('#global-search').fill('00000000-0000-0000-0002-000000000550');
  await page.locator('#global-search').press('Enter');
  await page.locator('.counterpart-focused').getByRole('button', { name: 'Technical details and identifiers', exact: true }).click();
  check((await page.locator('#technical-panel').innerText()).includes('00000000-0000-0000-0002-000000000550'), 'Global search navigates beyond the first page');
  await page.keyboard.press('Escape');
  check(await page.locator('.identity-item[aria-pressed="true"]').count() === 1, 'Global navigation reveals the selected identity page');
  await tab('credentials');
  const largeTable = page.locator('#credentials .data-table').first();
  check(await largeTable.locator('tbody tr').count() === 50, 'Large credential table is paged');
  await largeTable.getByRole('button', { name: 'Next', exact: true }).click();
  check((await largeTable.locator('tbody tr').first().innerText()).includes('0051'), 'Next page exposes more rows');
  await largeTable.getByRole('searchbox').fill('Synthetic credential 0225');
  check(await largeTable.locator('tbody tr').count() === 1, 'Credential search reaches beyond the old 200-row cap');
  await largeTable.getByRole('searchbox').fill('');
  await largeTable.getByRole('button', { name: 'Credential Display Name', exact: true }).click();
  await largeTable.getByRole('button', { name: 'Credential Display Name', exact: true }).click();
  check((await largeTable.locator('tbody tr').first().innerText()).includes('0225'), 'Table sorting operates on the complete dataset');
  await tab('raw');
  await page.locator('#raw summary').filter({ hasText: '02-inventory.json' }).click();
  const originalJson = await readFile(join(root, 'large/02-inventory.json'), 'utf8');
  check(originalJson.length > 200000, 'Large fixture exceeds the legacy raw JSON size limit');
  check(await page.locator('#raw details[open] pre').textContent() === originalJson, 'Raw JSON is complete and unchanged beyond the old truncation limit');

  for (const scenario of ['empty', 'single', 'single-object', 'partial', 'absent', 'invalid-shape']) {
    await open(scenario);
    if (scenario === 'empty') {
      check((await page.locator('#overview-cards .card-value').allTextContents()).slice(0, 4).every(value => value === '0'), 'Empty exports display true zero totals');
      await tab('monitoring');
      check((await page.locator('#monitoring').innerText()).includes('0'), 'Empty monitoring arrays do not become a phantom row');
    }
    if (scenario === 'single' || scenario === 'single-object') {
      await tab('inventory');
      check(await visibleCount('.identity-item') === 1, `${scenario}: single-record app/SP exports stay navigable as one workload`);
    }
    if (scenario === 'partial') {
      check((await page.locator('#overview-cards .card-value').allTextContents()).slice(0, 4).every(value => value === 'Unavailable'), 'Missing and partial data are not shown as zeros');
      for (const id of ['inventory', 'credentials', 'fic']) {
        await tab(id);
        check(await page.locator(`#${id} .notice`).count() === 1, `${id}: missing, partial or unreadable data is explicit`);
      }
      await tab('raw');
      check((await page.locator('#raw').innerText()).includes('03-credential-hygiene.json'), 'Partial raw export remains inspectable');
    }
    if (scenario === 'absent') {
      check(await visibleCount('#source-table .badge.missing') === 8, 'All absent datasets are reported');
      await tab('findings');
      check((await page.locator('#findings .notice:not(.permission-methodology)').innerText()).includes('not an all-clear'), 'Missing data cannot imply all-clear independently of the grading disclaimer');
    }
    if (scenario === 'invalid-shape') {
      check(await page.locator('#source-table .badge.partial').count() === 2, 'Invalid exported structures remain explicit rather than breaking the UI');
      check(await page.locator('#source-table .badge.unreadable').count() === 2, 'Non-object JSON roots remain unavailable');
    }
  }
  await open('no-signins');
  await tab('stale');
  check((await page.locator('#stale .notice').innerText()).includes('SignInDataAvailable = false'), 'Exported sign-in unavailability is surfaced');
  await open('unknown-hygiene');
  await tab('stale');
  check((await page.locator('#stale .tile-value').allTextContents()).slice(1, 4).join('|') === 'Unknown|Unknown|Unknown', 'Null hygiene activity totals stay visibly unknown while the valid dataset remains usable');
  check(await page.locator('#stale .tile').filter({ hasText: 'Observed activity age' }).evaluateAll(elements => elements.every(element => element.classList.contains('tone-neutral'))), 'Unknown activity totals are neither red/yellow failures nor green passes');
  await tab('findings');
  check(await page.locator('.finding').filter({ hasText: 'WI.OWN.3' }).count() === 1, 'Unknown activity does not hide independent ownership-continuity findings');
  await open('distinct-ids');
  await tab('inventory');
  check(await page.locator('#identity-detail .data-table').count() === 2, 'Client IDs cannot masquerade as SP object IDs in joins');

  await open('hostile');
  await tab('inventory');
  check((await page.locator('#identity-detail h3').innerText()).includes('</script>'), 'Hostile display name remains visible as literal text');
  check(await page.locator('img').count() === 0, 'Hostile markup creates no image element');
  check(await page.evaluate(() => window.reportInjection === undefined), 'Embedded closing-script text does not execute');
  await page.setViewportSize({ width: 390, height: 844 });
  for (const id of ['overview', 'inventory', 'findings', 'credentials', 'fic', 'permissions', 'stale', 'monitoring', 'ca', 'tenant', 'raw']) {
    await tab(id);
    await noOverflow(`mobile hostile ${id}`);
  }
  await open('normal');
  await page.setViewportSize({ width: 390, height: 844 });
  await tab('findings');
  await page.locator('.finding').first().locator('[data-finding-affected]').click();
  await noOverflow('mobile expanded findings table');
  check(await page.locator('.finding').first().locator('.finding-evidence').isVisible(), 'Mobile affected-count shortcut still exposes its evidence within the local table scroll area');
  await tab('inventory');
  await screenshot('mobile-identities.png');
  check(await page.locator('#identity-search').isVisible(), 'Mobile identity controls remain usable');
  await page.getByRole('button', { name: 'Technical details and identifiers', exact: true }).first().click();
  check(await page.locator('#technical-panel').evaluate(element => element.getBoundingClientRect().width <= innerWidth + 1), 'Mobile technical panel stays within the viewport');
  check(await page.locator('#technical-panel .properties dd').evaluateAll(elements => elements.every(element => element.getBoundingClientRect().width >= 250)), 'Mobile technical values have readable nonzero width');
  for (let i = 0; i < 12; i++) await page.keyboard.press('Tab');
  check(await page.locator('#technical-panel').evaluate(element => element.contains(document.activeElement)), 'Modal keyboard focus remains inside the technical panel');
  await page.keyboard.press('Escape');
  check(errors.length === 0, `No browser errors: ${errors.join('; ')}`);
  check(externalRequests.length === 0, `No external requests: ${externalRequests.join('; ')}`);
  console.log(`PASS: ${checks} offline browser checks. Screenshots: ${screenshots}`);
} finally {
  await context.close();
  await browser.close();
  await unlink(movedReport);
  await rmdir(moved);
}
