import { Cloud, Disc3, FolderOpen, HardDrive, Info, Network, Usb } from 'lucide-react';
import { Button } from '@/components/atoms/Button';
import { issuesFor, type PlanVolume } from '../contract';
import { driveLetter, formatBytes, samePath } from '../format';
import { Callout, IssueList, SpaceBar, Spinner } from '../ui';
import { selectedTotal, type Wizard } from '../useWizard';
import { CircleCheck, TriangleAlert } from 'lucide-react';

export const driveName = (volume: PlanVolume) => `${volume.label || (volume.driveType === 'removable' ? 'USB Drive' : 'Local Disk')} (${driveLetter(volume.root)})`;

function DriveIcon({ volume }: { volume: PlanVolume }) {
  const Icon = volume.driveType === 'removable' ? Usb : volume.driveType === 'cdrom' ? Disc3 : volume.driveType === 'network' ? Network : HardDrive;
  return <Icon size={20} aria-hidden="true" />;
}

function Badges({ volume }: { volume: PlanVolume }) {
  return (
    <span className="badges">
      {volume.recommended && volume.eligible && <span className="badge is-accent">Recommended</span>}
      {volume.isSystem ? <span className="badge is-warning">Windows drive</span>
        : volume.sameDiskAsSystem ? <span className="badge is-warning">Same disk as Windows</span> : null}
      {volume.driveType === 'removable' && <span className="badge">Removable</span>}
    </span>
  );
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
  const volumes = environment.volumes.filter(volume => volume.driveType !== 'network' || volume.eligible);
  const chosen = cloud
    ? volumes.find(volume => environment.drivefs.myDriveRoot && samePath(volume.root, environment.drivefs.myDriveRoot.slice(0, 3)))
    : volumes.find(volume => samePath(volume.root, choices.driveRoot));
  const anyEligible = volumes.some(volume => volume.eligible) || environment.drivefs.detected;

  return (
    <div className="screen-stack">
      <fieldset className="drive-group">
        <legend className="section-label">Drives on this PC</legend>
        {volumes.map(volume => {
          const selected = !cloud && samePath(volume.root, choices.driveRoot);
          const free = `${formatBytes(volume.freeBytes, locale)} free of ${formatBytes(volume.sizeBytes, locale)}`;
          return (
            <label key={volume.root} className="drive-card" data-selected={selected} data-disabled={!volume.eligible}>
              <input type="radio" name="backup-drive" className="sr-only" checked={selected} disabled={!volume.eligible}
                onChange={() => wizard.actions.chooseDrive(volume.root)} aria-describedby={`drive-${volume.root[0]}-detail`} />
              <span className="drive-icon"><DriveIcon volume={volume} /></span>
              <span className="drive-main">
                <span className="drive-title"><strong>{driveName(volume)}</strong><Badges volume={volume} /></span>
                {volume.eligible ? (
                  <>
                    <SpaceBar size={volume.sizeBytes} free={volume.freeBytes} adding={selected ? total.bytes : 0} label={free} />
                    <span className="drive-meta" id={`drive-${volume.root[0]}-detail`}>{free}{volume.filesystem && volume.filesystem !== 'NTFS' ? ` · ${volume.filesystem}` : ''}</span>
                  </>
                ) : (
                  <span className="drive-meta" id={`drive-${volume.root[0]}-detail`}>{volume.ineligibleReason ?? 'Backups can’t be kept on this drive.'}</span>
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
          Connect an external drive formatted as NTFS, then choose Back and Next to look again.
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

      <FitCheck bytes={total.bytes} measuring={total.measuring} volume={chosen} minimumFree={minimumFree} cloud={cloud} locale={locale} />

      <IssueList errors={errors} warnings={warnings} />

      {!cloud && (
        <p className="fine-print">
          <Info size={14} aria-hidden="true" />
          <span>A backup on a separate physical drive survives if the drive Windows runs from fails.</span>
        </p>
      )}
    </div>
  );
}

function FitCheck({ bytes, measuring, volume, minimumFree, cloud, locale }: { bytes: number; measuring: boolean; volume?: PlanVolume; minimumFree: number; cloud: boolean; locale?: string }) {
  if (!volume) return null;
  const where = cloud ? 'your Google storage' : driveLetter(volume.root);
  if (measuring) {
    return <p className="fit-line"><Spinner size={14} /> Measuring your folders to check they fit on {where}…</p>;
  }
  const room = Math.max(0, volume.freeBytes - minimumFree);
  const size = formatBytes(bytes, locale), free = formatBytes(volume.freeBytes, locale);
  if (bytes <= room / 2) {
    return <p className="fit-line is-good"><CircleCheck size={16} aria-hidden="true" /><span><strong>Plenty of room.</strong> Your folders take {size}, and {where} has {free} free.</span></p>;
  }
  if (bytes <= room) {
    return <p className="fit-line is-tight"><TriangleAlert size={16} aria-hidden="true" /><span><strong>It fits, but it’s tight.</strong> Your folders take {size}, and {where} has {free} free. Later backups add only what changed, but leave room to grow.</span></p>;
  }
  return (
    <p className="fit-line is-short"><TriangleAlert size={16} aria-hidden="true" />
      <span><strong>This probably won’t fit.</strong> Your folders take {size}, more than the {free} free on {where}{minimumFree > 0 ? ` (Rewindle keeps ${formatBytes(minimumFree, locale)} free)` : ''}. Backups are compressed, but choose a bigger drive or fewer folders to be safe.</span>
    </p>
  );
}
