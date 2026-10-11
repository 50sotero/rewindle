import { Cloud, Disc3, FolderOpen, HardDrive, Info, Network, Usb } from 'lucide-react';
import { Button } from '@/components/atoms/Button';
import { ineligibleText, issuesFor, type PlanEnvironment, type PlanVolume } from '../contract';
import { driveLetter, driveRoot, formatBytes, samePath } from '../format';
import { Callout, IssueList, SpaceBar, Spinner } from '../ui';
import { selectedTotal, type Choices, type Wizard } from '../useWizard';
import { CircleCheck, TriangleAlert } from 'lucide-react';

export const driveName = (volume: PlanVolume) => `${volume.label || (volume.driveType === 'removable' ? 'USB Drive' : 'Local Disk')} (${driveLetter(volume.root)})`;

function DriveIcon({ volume }: { volume: PlanVolume }) {
  const Icon = volume.driveType === 'removable' ? Usb : volume.driveType === 'cdrom' ? Disc3 : volume.driveType === 'network' ? Network : HardDrive;
  return <Icon size={20} aria-hidden="true" />;
}

function Badges({ volume, locale }: { volume: PlanVolume; locale?: string }) {
  return (
    <span className="badges">
      {/* A drive that can't be used shows no space bar, so its size is what tells two USB sticks apart. */}
      {!volume.eligible && volume.sizeBytes > 0 && <span className="badge">{formatBytes(volume.sizeBytes, locale)}</span>}
      {volume.recommended && volume.eligible && <span className="badge is-accent">Recommended</span>}
      {volume.isSystem ? <span className="badge is-warning">Windows drive</span>
        : volume.sameDiskAsSystem ? <span className="badge is-warning">Same disk as Windows</span> : null}
      {volume.driveType === 'removable' && <span className="badge">Removable</span>}
    </span>
  );
}

/** The drive the chosen backup location is on; for Google Drive, the drive Google Drive for desktop shows in Windows. */
export function chosenVolume(environment: PlanEnvironment, choices: Choices): PlanVolume | undefined {
  const myDrive = environment.drivefs.myDriveRoot;
  return choices.storageMode === 'google_drivefs_stream'
    ? environment.volumes.find(volume => !!myDrive && samePath(volume.root, myDrive.slice(0, 3)))
    : environment.volumes.find(volume => samePath(volume.root, choices.driveRoot));
}

/** Step 2: where the backups are kept. Drives are radio cards; Google Drive for desktop is offered when it is running. */
export function Location({ wizard }: { wizard: Wizard }) {
  const choices = wizard.choices!;
  const environment = wizard.base!.environment;
  const locale = wizard.host?.locale;
  const plan = wizard.validation.plan;
  const minimumFree = plan?.resolved.minimumFreeBytes ?? 0;
  const total = selectedTotal(choices, wizard.sizes);
  const { errors, warnings } = issuesFor(plan, 'repository', 'storage_mode');
  const cloud = choices.storageMode === 'google_drivefs_stream';
  // A disc drive or a RAM disk is never a place for backups, so it is not listed; every other drive is, with the reason when it can't be used.
  const volumes = environment.volumes.filter(volume => volume.driveType !== 'cdrom' && volume.driveType !== 'ram');
  const chosen = chosenVolume(environment, choices);
  const anyEligible = volumes.some(volume => volume.eligible) || environment.drivefs.detected;
  // A reinstall carries on with the backups the removed copy kept, when their drive is there (see initialChoices); when it isn't,
  // Setup would start a new, empty backup elsewhere, which the person should hear before it happens.
  const kept = wizard.keptRepository;
  const keptMissing = !!kept && !samePath(choices.repository, kept) && !environment.volumes.some(volume => volume.eligible && samePath(volume.root, driveRoot(kept)));
  const earlier = warnings.some(warning => warning.code === 'repository_exists');
  const onSystemDisk = warnings.some(warning => warning.code === 'repository_on_system_disk');

  return (
    <div className="screen-stack">
      <div className="section-row drives-row">
        <span id="drives-label" className="section-label">Drives on this PC</span>
        <span className="refresh-inline">
          {wizard.refreshing && <Spinner size={12} />}
          {wizard.refreshNote && !wizard.refreshing && <span className="refresh-note" aria-hidden="true">{wizard.refreshNote}</span>}
          <button type="button" className="text-link" disabled={wizard.refreshing} onClick={() => void wizard.actions.refreshDrives()}
            title="Connected a drive just now? It shows up here after you look again.">Look for drives again</button>
          <span className="sr-only" role="status" aria-live="polite">{wizard.refreshNote ?? ''}</span>
        </span>
      </div>
      <fieldset className="drive-group" aria-labelledby="drives-label">
        {volumes.map(volume => {
          const selected = !cloud && samePath(volume.root, choices.driveRoot);
          const free = `${formatBytes(volume.freeBytes, locale)} free of ${formatBytes(volume.sizeBytes, locale)}`;
          const isDriveFs = environment.drivefs.detected && !!environment.drivefs.myDriveRoot && samePath(volume.root, environment.drivefs.myDriveRoot.slice(0, 3));
          return (
            <label key={volume.root} className="drive-card" data-selected={selected} data-disabled={!volume.eligible}>
              <input type="radio" name="backup-drive" className="sr-only" checked={selected} disabled={!volume.eligible}
                onChange={() => wizard.actions.chooseDrive(volume.root)} aria-describedby={`drive-${volume.root[0]}-detail`} />
              <span className="drive-icon"><DriveIcon volume={volume} /></span>
              <span className="drive-main">
                <span className="drive-title"><strong>{driveName(volume)}</strong><Badges volume={volume} locale={locale} /></span>
                {volume.eligible ? (
                  <>
                    <SpaceBar size={volume.sizeBytes} free={volume.freeBytes} adding={selected ? total.bytes : 0} label={free} />
                    <span className="drive-meta" id={`drive-${volume.root[0]}-detail`}>{free}{volume.filesystem && volume.filesystem !== 'NTFS' ? ` · ${volume.filesystem}` : ''}</span>
                  </>
                ) : (
                  <span className="drive-meta" id={`drive-${volume.root[0]}-detail`}>
                    {ineligibleText(volume)}
                    {/* A new USB drive is usually exFAT or FAT32: say how to fix it, and that it erases the drive. */}
                    {volume.ineligibleReason === 'not_ntfs' && !isDriveFs && (
                      <span className="drive-help">To use it, format it as NTFS: in File Explorer, right-click the drive, choose Format, and set File system to NTFS. Formatting erases everything on the drive, so copy off anything you need first.</span>
                    )}
                  </span>
                )}
              </span>
              <span className="radio-dot" aria-hidden="true" />
            </label>
          );
        })}
        {environment.drivefs.detected && environment.drivefs.myDriveRoot && (
          <>
            <p className="group-divider">Or keep them in the cloud</p>
            <label className="drive-card is-cloud" data-selected={cloud}>
              <input type="radio" name="backup-drive" className="sr-only" checked={cloud} onChange={() => wizard.actions.chooseDriveFs()} aria-describedby="drive-cloud-detail" />
              <span className="drive-icon"><Cloud size={20} aria-hidden="true" /></span>
              <span className="drive-main">
                <span className="drive-title"><strong>Google Drive</strong><span className="badges"><span className="badge">Off-site</span></span></span>
                <span className="drive-meta" id="drive-cloud-detail">
                  Backups go to your My Drive folder ({environment.drivefs.myDriveRoot}), and Google Drive for desktop uploads them, so a copy lives away from this PC. Keep it running and signed in, with at least 10 GB free on this PC for its cache.
                </span>
              </span>
              <span className="radio-dot" aria-hidden="true" />
            </label>
          </>
        )}
      </fieldset>

      {!anyEligible && (
        <Callout tone="error" title="No drive here can hold backups">
          Connect an external hard drive or SSD, then choose “Look for drives again”. A drive that is connected but greyed out above probably needs formatting as NTFS (Windows’ usual format), which erases it.
        </Callout>
      )}

      {choices.repository && (
        <div className="destination">
          <span className="destination-label">Backups will be saved in</span>
          <div className="destination-row">
            <FolderOpen size={18} aria-hidden="true" />
            <span className="destination-path" title={choices.repository}>{choices.repository}</span>
            <Button size="sm" onClick={() => void wizard.actions.browseRepository()}>Choose a different folder…</Button>
          </div>
        </div>
      )}

      {wizard.notice?.screen === 'location' && (
        <div role="alert"><Callout tone="error" title="That folder can’t be used">{wizard.notice.text}</Callout></div>
      )}

      <FitCheck bytes={total.bytes} measuring={total.measuring} volume={chosen} minimumFree={minimumFree} cloud={cloud} locale={locale} onFolders={() => wizard.goTo('folders')} />

      {keptMissing && (
        <div className="callout is-warning" role="status">
          <TriangleAlert size={16} aria-hidden="true" />
          <span>Your earlier backups are at <span className="inline-path">{kept}</span>, but that drive isn’t available. Connect it and choose Look for drives again, or Setup starts a new, empty backup in the location above.</span>
          <Button size="sm" className="issue-action" disabled={wizard.refreshing} onClick={() => void wizard.actions.refreshDrives()}>Look for drives again</Button>
        </div>
      )}

      {/* "Already holds a backup" is good news (a reinstall carries on with it), so it is not drawn as a warning. */}
      <IssueList errors={errors} warnings={warnings.filter(warning => warning.code !== 'repository_exists')}
        action={issue => issue.code === 'repository_on_system_disk'
          ? <Button size="sm" className="issue-action" disabled={wizard.refreshing} onClick={() => void wizard.actions.refreshDrives()}>Look for drives again</Button>
          : null} />
      {earlier && (
        <Callout tone="success" icon={<CircleCheck size={16} aria-hidden="true" />} title="Your earlier backups are here">
          Setup keeps them and carries on, so every earlier day stays available to restore.
        </Callout>
      )}

      {!cloud && (
        <p className="fine-print">
          <Info size={14} aria-hidden="true" />
          <span>{onSystemDisk
            ? 'No spare drive? You can carry on, and move your backups to a separate drive later: in Rewindle, open Settings and choose Change location.'
            : 'A backup on a separate physical drive survives if the drive Windows runs from fails.'}</span>
        </p>
      )}
    </div>
  );
}

/** How the chosen folders compare with the room on the drive: good (under half of it), tight, or short. */
export function fitOf(bytes: number, volume: PlanVolume, minimumFree: number): 'good' | 'tight' | 'short' {
  const room = Math.max(0, volume.freeBytes - minimumFree);
  return bytes <= room / 2 ? 'good' : bytes <= room ? 'tight' : 'short';
}

/** `onlyShort` is for Review, which repeats the check only when the folders won't fit: a line of good news there would be noise. */
export function FitCheck({ bytes, measuring, volume, minimumFree, cloud, locale, onFolders, onlyShort }: {
  bytes: number; measuring: boolean; volume?: PlanVolume; minimumFree: number; cloud: boolean; locale?: string; onFolders?: () => void; onlyShort?: boolean;
}) {
  if (!volume) return null;
  const where = cloud ? 'Google Drive' : driveLetter(volume.root);
  if (measuring) {
    return onlyShort ? null : <p className="fit-line"><Spinner size={14} /> Measuring your folders to check they fit on {where}…</p>;
  }
  const size = formatBytes(bytes, locale), free = formatBytes(volume.freeBytes, locale);
  const fit = fitOf(bytes, volume, minimumFree);
  if (fit === 'good') {
    return onlyShort ? null : <p className="fit-line is-good"><CircleCheck size={16} aria-hidden="true" /><span><strong>Plenty of room.</strong> Your folders take {size}, and {where} has {free} free.</span></p>;
  }
  if (fit === 'tight') {
    return onlyShort ? null : <p className="fit-line is-tight"><TriangleAlert size={16} aria-hidden="true" /><span><strong>It fits, but it’s tight.</strong> Your folders take {size}, and {where} has {free} free. Later backups add only what changed, but leave room to grow.</span></p>;
  }
  // Photos, videos and music hardly shrink, so "compressed" would promise room that isn't there; the way out is named, not just the problem.
  return (
    <p className="fit-line is-short"><TriangleAlert size={16} aria-hidden="true" />
      <span><strong>This probably won’t fit.</strong> Your folders take {size}, but {where} has {free} free{minimumFree > 0 ? ` (Rewindle keeps ${formatBytes(minimumFree, locale)} free)` : ''}. Photos, videos and music hardly shrink, so plan for about that much. Choose a bigger drive{onFolders ? <>, or <button type="button" className="text-link" onClick={onFolders}>protect fewer folders</button></> : ' or fewer folders'}.</span>
    </p>
  );
}
